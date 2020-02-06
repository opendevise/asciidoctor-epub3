# frozen_string_literal: true

require_relative 'spine_item_processor'
require_relative 'font_icon_map'

module Asciidoctor
  module Epub3
    # Public: The main converter for the epub3 backend that handles packaging the
    # EPUB3 or KF8 publication file.
    class Converter
      include ::Asciidoctor::Converter
      include ::Asciidoctor::Logging
      include ::Asciidoctor::Writer

      register_for 'epub3'

      def initialize backend, opts
        super
        basebackend 'html'
        outfilesuffix '.epub' # dummy outfilesuffix since it may be .mobi
        htmlsyntax 'xml'
        @validate = false
        @extract = false
        @kindlegen_path = nil
        @epubcheck_path = nil
      end

      def convert node, name = nil
        if (name ||= node.node_name) == 'document'
          @validate = node.attr? 'ebook-validate'
          @extract = node.attr? 'ebook-extract'
          @compress = node.attr 'ebook-compress'
          @kindlegen_path = node.attr 'ebook-kindlegen-path'
          @epubcheck_path = node.attr 'ebook-epubcheck-path'
          spine_items = node.references[:spine_items]
          if spine_items.nil?
            logger.error %(#{::File.basename node.document.attr('docfile')}: failed to find spine items, produced file will be invalid)
            spine_items = []
          end
          Packager.new node, spine_items, node.attributes['ebook-format'].to_sym
          # converting an element from the spine document, such as an inline node in the doctitle
        elsif name.start_with? 'inline_'
          (@content_converter ||= ::Asciidoctor::Converter::Factory.default.create 'epub3-xhtml5').convert node, name
        else
          raise ::ArgumentError, %(Encountered unexpected node in epub3 package converter: #{name})
        end
      end

      # FIXME: we have to package in write because we don't have access to target before this point
      def write packager, target
        packager.package validate: @validate, extract: @extract, compress: @compress, kindlegen_path: @kindlegen_path, epubcheck_path: @epubcheck_path, target: target
        nil
      end
    end

    # Public: The converter for the epub3 backend that converts the individual
    # content documents in an EPUB3 publication.
    class ContentConverter
      include ::Asciidoctor::Converter
      include ::Asciidoctor::Logging

      register_for 'epub3-xhtml5'

      LF = ?\n
      NoBreakSpace = '&#xa0;'
      ThinNoBreakSpace = '&#x202f;'
      RightAngleQuote = '&#x203a;'
      CalloutStartNum = %(\u2460)

      CharEntityRx = /&#(\d{2,6});/
      XmlElementRx = /<\/?.+?>/
      TrailingPunctRx = /[[:punct:]]$/

      FromHtmlSpecialCharsMap = {
        '&lt;' => '<',
        '&gt;' => '>',
        '&amp;' => '&',
      }

      FromHtmlSpecialCharsRx = /(?:#{FromHtmlSpecialCharsMap.keys * '|'})/

      ToHtmlSpecialCharsMap = {
        '&' => '&amp;',
        '<' => '&lt;',
        '>' => '&gt;',
      }

      ToHtmlSpecialCharsRx = /[#{ToHtmlSpecialCharsMap.keys.join}]/

      def initialize backend, opts
        super
        basebackend 'html'
        outfilesuffix '.xhtml'
        htmlsyntax 'xml'
        @xrefs_seen = ::Set.new
        @icon_names = []
      end

      def convert node, name = nil, _opts = {}
        method_name = %(convert_#{name ||= node.node_name})
        if respond_to? method_name
          send method_name, node
        else
          logger.warn %(conversion missing in backend #{@backend} for #{name})
        end
      end

      def convert_document node
        docid = node.id
        pubtype = node.attr 'publication-type', 'book'

        if (doctitle = node.doctitle partition: true, use_fallback: true).subtitle?
          title = %(#{doctitle.main} )
          subtitle = doctitle.subtitle
        else
          # HACK: until we get proper handling of title-only in CSS
          title = ''
          subtitle = doctitle.combined
        end

        doctitle_sanitized = (node.doctitle sanitize: true, use_fallback: true).to_s

        # By default, Kindle does not allow the line height to be adjusted.
        # But if you float the elements, then the line height disappears and can be restored manually using margins.
        # See https://github.com/asciidoctor/asciidoctor-epub3/issues/123
        subtitle_formatted = subtitle.split.map {|w| %(<b>#{w}</b>) } * ' '

        if pubtype == 'book'
          byline = ''
        else
          author = node.attr 'author'
          username = node.attr 'username', 'default'
          imagesdir = (node.references[:spine].attr 'imagesdir', '.').chomp '/'
          imagesdir = imagesdir == '.' ? '' : %(#{imagesdir}/)
          byline = %(<p class="byline"><img src="#{imagesdir}avatars/#{username}.jpg"/> <b class="author">#{author}</b></p>#{LF})
        end

        mark_last_paragraph node unless pubtype == 'book'
        content = node.content

        # NOTE must run after content is resolved
        # TODO perhaps create dynamic CSS file?
        if @icon_names.empty?
          icon_css_head = ''
        else
          icon_defs = @icon_names.map {|name|
            %(.i-#{name}::before { content: "#{FontIconMap.unicode name}"; })
          } * LF
          icon_css_head = %(<style>
#{icon_defs}
</style>
)
        end

        # NOTE kindlegen seems to mangle the <header> element, so we wrap its content in a div
        lines = [%(<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="#{lang = node.attr 'lang', 'en'}" lang="#{lang}">
<head>
<meta charset="UTF-8"/>
<title>#{doctitle_sanitized}</title>
<link rel="stylesheet" type="text/css" href="styles/epub3.css"/>
<link rel="stylesheet" type="text/css" href="styles/epub3-css3-only.css" media="(min-device-width: 0px)"/>
#{icon_css_head}<script type="text/javascript"><![CDATA[
document.addEventListener('DOMContentLoaded', function(event, reader) {
  if (!(reader = navigator.epubReadingSystem)) {
    if (navigator.userAgent.indexOf(' calibre/') >= 0) reader = { name: 'calibre-desktop' };
    else if (window.parent == window || !(reader = window.parent.navigator.epubReadingSystem)) return;
  }
  document.body.setAttribute('class', reader.name.toLowerCase().replace(/ /g, '-'));
});
]]></script>
</head>
<body>
<section class="chapter" title="#{doctitle_sanitized.gsub '"', '&quot;'}" epub:type="chapter" id="#{docid}">
<header>
<div class="chapter-header">
#{byline}<h1 class="chapter-title">#{title}#{subtitle ? %(<small class="subtitle">#{subtitle_formatted}</small>) : ''}</h1>
</div>
</header>
#{content})]

        if node.footnotes?
          # NOTE kindlegen seems to mangle the <footer> element, so we wrap its content in a div
          lines << '<footer>
<div class="chapter-footer">
<div class="footnotes">'
          node.footnotes.each do |footnote|
            lines << %(<aside id="note-#{footnote.index}" epub:type="footnote">
<p><sup class="noteref"><a href="#noteref-#{footnote.index}">#{footnote.index}</a></sup> #{footnote.text}</p>
</aside>)
          end
          lines << '</div>
</div>
</footer>'
        end

        lines << '</section>
</body>
</html>'

        lines * LF
      end

      # NOTE embedded is used for AsciiDoc table cell content
      def convert_embedded node
        node.content
      end

      def convert_section node
        hlevel = node.level + 1
        epub_type_attr = node.special ? %( epub:type="#{node.sectname}") : ''
        div_classes = [%(sect#{node.level}), node.role].compact
        title = node.title
        title_sanitized = xml_sanitize title
        if node.document.header? || node.level != 1 || node != node.document.first_section
          %(<section class="#{div_classes * ' '}" title="#{title_sanitized}"#{epub_type_attr}>
<h#{hlevel} id="#{node.id}">#{title}</h#{hlevel}>#{(content = node.content).empty? ? '' : %(
          #{content})}
</section>)
        else
          # document has no level-0 heading and this heading serves as the document title
          node.content
        end
      end

      # TODO: support use of quote block as abstract
      def convert_preamble node
        if (first_block = node.blocks[0]) && first_block.style == 'abstract'
          convert_abstract first_block
          # REVIEW: should we treat the preamble as an abstract in general?
        elsif first_block && node.blocks.size == 1
          convert_abstract first_block
        else
          node.content
        end
      end

      def convert_open node
        id_attr = node.id ? %( id="#{node.id}") : nil
        class_attr = node.role ? %( class="#{node.role}") : nil
        if id_attr || class_attr
          %(<div#{id_attr}#{class_attr}>
#{output_content node}
</div>)
        else
          output_content node
        end
      end

      def convert_abstract node
        %(<div class="abstract" epub:type="preamble">
#{output_content node}
</div>)
      end

      def convert_paragraph node
        role = node.role
        # stack-head is the alternative to the default, inline-head (where inline means "run-in")
        head_stop = node.attr 'head-stop', (role && (node.has_role? 'stack-head') ? nil : '.')
        head = node.title? ? %(<strong class="head">#{title = node.title}#{head_stop && title !~ TrailingPunctRx ? head_stop : ''}</strong> ) : ''
        if role
          node.set_option 'hardbreaks' if node.has_role? 'signature'
          %(<p class="#{role}">#{head}#{node.content}</p>)
        else
          %(<p>#{head}#{node.content}</p>)
        end
      end

      def convert_pass node
        content = node.content
        if content == '<?hard-pagebreak?>'
          '<hr epub:type="pagebreak" class="pagebreak"/>'
        else
          content
        end
      end

      def convert_admonition node
        id_attr = node.id ? %( id="#{node.id}") : ''
        if node.title?
          title = node.title
          title_sanitized = xml_sanitize title
          title_attr = %( title="#{node.caption}: #{title_sanitized}")
          title_el = %(<h2>#{title}</h2>
)
        else
          title_attr = %( title="#{node.caption}")
          title_el = ''
        end

        type = node.attr 'name'
        epub_type = case type
                    when 'tip'
                      'help'
                    when 'note'
                      'note'
                    when 'important', 'warning', 'caution'
                      'warning'
                    end
        %(<aside#{id_attr} class="admonition #{type}"#{title_attr} epub:type="#{epub_type}">
#{title_el}<div class="content">
#{output_content node}
</div>
</aside>)
      end

      def convert_example node
        id_attr = node.id ? %( id="#{node.id}") : ''
        title_div = node.title? ? %(<div class="example-title">#{node.title}</div>
) : ''
        %(<div#{id_attr} class="example">
#{title_div}<div class="example-content">
#{output_content node}
</div>
</div>)
      end

      def convert_floating_title node
        tag_name = %(h#{node.level + 1})
        id_attribute = node.id ? %( id="#{node.id}") : ''
        %(<#{tag_name}#{id_attribute} class="#{['discrete', node.role].compact * ' '}">#{node.title}</#{tag_name}>)
      end

      def convert_listing node
        figure_classes = ['listing']
        figure_classes << 'coalesce' if node.option? 'unbreakable'
        pre_classes = node.style == 'source' ? ['source', %(language-#{node.attr 'language'})] : ['screen']
        title_div = node.title? ? %(<figcaption>#{node.captioned_title}</figcaption>
) : ''
        # patches conums to fix extra or missing leading space
        # TODO remove patch once upgrading to Asciidoctor 1.5.6
        %(<figure class="#{figure_classes * ' '}">
#{title_div}<pre class="#{pre_classes * ' '}"><code>#{(node.content || '').gsub(/(?<! )<i class="conum"| +<i class="conum"/, ' <i class="conum"')}</code></pre>
</figure>)
      end

      # TODO: implement proper stem support. See https://github.com/asciidoctor/asciidoctor-epub3/issues/10
      alias convert_stem convert_listing

      # QUESTION should we wrap the <pre> in either <div> or <figure>?
      def convert_literal node
        %(<pre class="screen">#{node.content}</pre>)
      end

      def convert_page_break _node
        '<hr epub:type="pagebreak" class="pagebreak"/>'
      end

      def convert_thematic_break _node
        '<hr class="thematicbreak"/>'
      end

      def convert_quote node
        id_attr = %( id="#{node.id}") if node.id
        class_attr = (role = node.role) ? %( class="blockquote #{role}") : ' class="blockquote"'

        footer_content = []
        if (attribution = node.attr 'attribution')
          footer_content << attribution
        end

        if (citetitle = node.attr 'citetitle')
          citetitle_sanitized = xml_sanitize citetitle
          footer_content << %(<cite title="#{citetitle_sanitized}">#{citetitle}</cite>)
        end

        footer_content << %(<span class="context">#{node.title}</span>) if node.title?

        footer_tag = footer_content.empty? ? '' : %(
<footer>~ #{footer_content * ' '}</footer>)
        content = (output_content node).strip
        %(<div#{id_attr}#{class_attr}>
<blockquote>
#{content}#{footer_tag}
</blockquote>
</div>)
      end

      def convert_verse node
        id_attr = %( id="#{node.id}") if node.id
        class_attr = (role = node.role) ? %( class="verse #{role}") : ' class="verse"'

        footer_content = []
        if (attribution = node.attr 'attribution')
          footer_content << attribution
        end

        if (citetitle = node.attr 'citetitle')
          citetitle_sanitized = xml_sanitize citetitle
          footer_content << %(<cite title="#{citetitle_sanitized}">#{citetitle}</cite>)
        end

        footer_tag = !footer_content.empty? ? %(
<span class="attribution">~ #{footer_content * ', '}</span>) : ''
        %(<div#{id_attr}#{class_attr}>
<pre>#{node.content}#{footer_tag}</pre>
</div>)
      end

      def convert_sidebar node
        classes = ['sidebar']
        if node.title?
          classes << 'titled'
          title = node.title
          title_sanitized = xml_sanitize title
          title_attr = %( title="#{title_sanitized}")
          title_el = %(<h2>#{title}</h2>
)
        else
          title_attr = title_el = ''
        end

        %(<aside class="#{classes * ' '}"#{title_attr} epub:type="sidebar">
#{title_el}<div class="content">
#{output_content node}
</div>
</aside>)
      end

      def convert_table node
        lines = [%(<div class="table">)]
        lines << %(<div class="content">)
        table_id_attr = node.id ? %( id="#{node.id}") : ''
        frame_class = {
          'all' => 'table-framed',
          'topbot' => 'table-framed-topbot',
          'sides' => 'table-framed-sides',
          'none' => '',
        }
        grid_class = {
          'all' => 'table-grid',
          'rows' => 'table-grid-rows',
          'cols' => 'table-grid-cols',
          'none' => '',
        }
        table_classes = %W[table #{frame_class[node.attr 'frame'] || frame_class['topbot']} #{grid_class[node.attr 'grid'] || grid_class['rows']}]
        if (role = node.role)
          table_classes << role
        end
        table_class_attr = %( class="#{table_classes * ' '}")
        table_styles = []
        table_styles << %(width: #{node.attr 'tablepcwidth'}%) unless (node.option? 'autowidth') && !(node.attr? 'width', nil, false)
        table_style_attr = !table_styles.empty? ? %( style="#{table_styles * '; '}") : ''

        lines << %(<table#{table_id_attr}#{table_class_attr}#{table_style_attr}>)
        lines << %(<caption>#{node.captioned_title}</caption>) if node.title?
        if (node.attr 'rowcount') > 0
          lines << '<colgroup>'
          #if node.option? 'autowidth'
          tag = %(<col/>)
          node.columns.size.times do
            lines << tag
          end
          #else
          #  node.columns.each do |col|
          #    lines << %(<col style="width: #{col.attr 'colpcwidth'}%"/>)
          #  end
          #end
          lines << '</colgroup>'
          [:head, :foot, :body].reject {|tsec| node.rows[tsec].empty? }.each do |tsec|
            lines << %(<t#{tsec}>)
            node.rows[tsec].each do |row|
              lines << '<tr>'
              row.each do |cell|
                if tsec == :head
                  cell_content = cell.text
                else
                  case cell.style
                  when :asciidoc
                    cell_content = %(<div class="embed">#{cell.content}</div>)
                  when :verse
                    cell_content = %(<div class="verse">#{cell.text}</div>)
                  when :literal
                    cell_content = %(<div class="literal"><pre>#{cell.text}</pre></div>)
                  else
                    cell_content = ''
                    cell.content.each do |text|
                      cell_content = %(#{cell_content}<p>#{text}</p>)
                    end
                  end
                end

                cell_tag_name = tsec == :head || cell.style == :header ? 'th' : 'td'
                cell_classes = []
                if (halign = cell.attr 'halign') && halign != 'left'
                  cell_classes << 'halign-left'
                end
                if (halign = cell.attr 'valign') && halign != 'top'
                  cell_classes << 'valign-top'
                end
                cell_class_attr = !cell_classes.empty? ? %( class="#{cell_classes * ' '}") : ''
                cell_colspan_attr = cell.colspan ? %( colspan="#{cell.colspan}") : ''
                cell_rowspan_attr = cell.rowspan ? %( rowspan="#{cell.rowspan}") : ''
                cell_style_attr = (node.document.attr? 'cellbgcolor') ? %( style="background-color: #{node.document.attr 'cellbgcolor'}") : ''
                lines << %(<#{cell_tag_name}#{cell_class_attr}#{cell_colspan_attr}#{cell_rowspan_attr}#{cell_style_attr}>#{cell_content}</#{cell_tag_name}>)
              end
              lines << '</tr>'
            end
            lines << %(</t#{tsec}>)
          end
        end
        lines << '</table>
</div>
</div>'
        lines * LF
      end

      def convert_colist node
        lines = ['<div class="callout-list">
<ol>']
        num = CalloutStartNum
        node.items.each_with_index do |item, i|
          lines << %(<li><i class="conum" data-value="#{i + 1}">#{num}</i> #{item.text}</li>)
          num = num.next
        end
        lines << '</ol>
</div>'
      end

      # TODO: add complex class if list has nested blocks
      def convert_dlist node
        lines = []
        case (style = node.style)
        when 'itemized', 'ordered'
          list_tag_name = style == 'itemized' ? 'ul' : 'ol'
          role = node.role
          subject_stop = node.attr 'subject-stop', (role && (node.has_role? 'stack') ? nil : ':')
          # QUESTION should we just use itemized-list and ordered-list as the class here? or just list?
          div_classes = [%(#{style}-list), role].compact
          list_class_attr = (node.option? 'brief') ? ' class="brief"' : ''
          lines << %(<div class="#{div_classes * ' '}">
<#{list_tag_name}#{list_class_attr}#{list_tag_name == 'ol' && (node.option? 'reversed') ? ' reversed="reversed"' : ''}>)
          node.items.each do |subjects, dd|
            # consists of one term (a subject) and supporting content
            subject = [*subjects].first.text
            subject_plain = xml_sanitize subject, :plain
            subject_element = %(<strong class="subject">#{subject}#{subject_stop && subject_plain !~ TrailingPunctRx ? subject_stop : ''}</strong>)
            lines << '<li>'
            if dd
              # NOTE: must wrap remaining text in a span to help webkit justify the text properly
              lines << %(<span class="principal">#{subject_element}#{dd.text? ? %( <span class="supporting">#{dd.text}</span>) : ''}</span>)
              lines << dd.content if dd.blocks?
            else
              lines << %(<span class="principal">#{subject_element}</span>)
            end
            lines << '</li>'
          end
          lines << %(</#{list_tag_name}>
</div>)
        else
          lines << '<div class="description-list">
<dl>'
          node.items.each do |terms, dd|
            [*terms].each do |dt|
              lines << %(<dt>
<span class="term">#{dt.text}</span>
</dt>)
            end
            next unless dd
            lines << '<dd>'
            if dd.blocks?
              lines << %(<span class="principal">#{dd.text}</span>) if dd.text?
              lines << dd.content
            else
              lines << %(<span class="principal">#{dd.text}</span>)
            end
            lines << '</dd>'
          end
          lines << '</dl>
</div>'
        end
        lines * LF
      end

      def convert_olist node
        complex = false
        div_classes = ['ordered-list', node.style, node.role].compact
        ol_classes = [node.style, ((node.option? 'brief') ? 'brief' : nil)].compact
        ol_class_attr = ol_classes.empty? ? '' : %( class="#{ol_classes * ' '}")
        ol_start_attr = (node.attr? 'start') ? %( start="#{node.attr 'start'}") : ''
        id_attribute = node.id ? %( id="#{node.id}") : ''
        lines = [%(<div#{id_attribute} class="#{div_classes * ' '}">)]
        lines << %(<h3 class="list-heading">#{node.title}</h3>) if node.title?
        lines << %(<ol#{ol_class_attr}#{ol_start_attr}#{(node.option? 'reversed') ? ' reversed="reversed"' : ''}>)
        node.items.each do |item|
          lines << %(<li>
<span class="principal">#{item.text}</span>)
          if item.blocks?
            lines << item.content
            complex = true unless item.blocks.size == 1 && ::Asciidoctor::List === item.blocks[0]
          end
          lines << '</li>'
        end
        if complex
          div_classes << 'complex'
          lines[0] = %(<div class="#{div_classes * ' '}">)
        end
        lines << '</ol>
</div>'
        lines * LF
      end

      def convert_ulist node
        complex = false
        div_classes = ['itemized-list', node.style, node.role].compact
        ul_classes = [node.style, ((node.option? 'brief') ? 'brief' : nil)].compact
        ul_class_attr = ul_classes.empty? ? '' : %( class="#{ul_classes * ' '}")
        id_attribute = node.id ? %( id="#{node.id}") : ''
        lines = [%(<div#{id_attribute} class="#{div_classes * ' '}">)]
        lines << %(<h3 class="list-heading">#{node.title}</h3>) if node.title?
        lines << %(<ul#{ul_class_attr}>)
        node.items.each do |item|
          lines << %(<li>
<span class="principal">#{item.text}</span>)
          if item.blocks?
            lines << item.content
            complex = true unless item.blocks.size == 1 && ::Asciidoctor::List === item.blocks[0]
          end
          lines << '</li>'
        end
        if complex
          div_classes << 'complex'
          lines[0] = %(<div class="#{div_classes * ' '}">)
        end
        lines << '</ul>
</div>'
        lines * LF
      end

      def doc_option document, key
        loop do
          value = document.options[key]
          return value unless value.nil?
          document = document.parent_document
          break if document.nil?
        end
        nil
      end

      def root_document document
        document = document.parent_document until document.parent_document.nil?
        document
      end

      def register_image node, target
        out_dir = node.attr('outdir', nil, true) || doc_option(node.document, :to_dir)
        unless ::File.exist? fs_path = (::File.join out_dir, target)
          # This is actually a hack. It would be more correct to set base_dir of chapter document to base_dir of spine document.
          # That's how things would normally work if there was no separation between these documents, and instead chapters were normally included into spine document.
          # However, setting chapter base_dir to spine base_dir breaks parser.rb because it resolves includes in chapter document relative to base_dir instead of actual location of chapter file.
          # Choosing between two evils - a hack here or writing a full-blown include processor for chapter files, I chose the former.
          # In the future, this all should be thrown away when we stop parsing chapters as a standalone documents.
          # https://github.com/asciidoctor/asciidoctor-epub3/issues/47 is used to track that.
          base_dir = root_document(node.document).references[:spine].base_dir
          fs_path = ::File.join base_dir, target
        end
        # We need *both* virtual and physical image paths. Unfortunately, references[:images] only has one of them.
        (root_document(node.document).references[:epub_images] ||= []) << { name: target, path: fs_path } if doc_option node.document, :catalog_assets
      end

      def resolve_image_attrs node
        img_attrs = []
        img_attrs << %(alt="#{node.attr 'alt'}") if node.attr? 'alt'

        width = node.attr 'scaledwidth'
        width = node.attr 'width' if width.nil?

        # Unlike browsers, Calibre/Kindle *do* scale image if only height is specified
        # So, in order to match browser behavior, we just always omit height
        img_attrs << %(width="#{width}") unless width.nil?

        img_attrs
      end

      def convert_image node
        target = node.image_uri node.attr 'target'
        register_image node, target
        type = (::File.extname target)[1..-1]
        id_attr = node.id ? %( id="#{node.id}") : ''
        case type
        when 'svg'
          # TODO: make this a convenience method on document
          epub_properties = (node.document.attributes['epub-properties'] ||= [])
          epub_properties << 'svg' unless epub_properties.include? 'svg'
        end
        img_attrs = resolve_image_attrs node
        %(<figure#{id_attr} class="image#{prepend_space node.role}">
<div class="content">
<img src="#{target}"#{prepend_space img_attrs * ' '} />
</div>#{node.title? ? %(
<figcaption>#{node.captioned_title}</figcaption>) : ''}
</figure>)
      end

      def convert_inline_anchor node
        target = node.target
        case node.type
        when :xref # TODO: would be helpful to know what type the target is (e.g., bibref)
          doc, refid, text, path = node.document, ((node.attr 'refid') || target), node.text, (node.attr 'path')
          # NOTE if path is non-nil, we have an inter-document xref
          # QUESTION should we drop the id attribute for an inter-document xref?
          if path
            # ex. chapter-id#section-id
            if node.attr 'fragment'
              refdoc_id, refdoc_refid = refid.split '#', 2
              if refdoc_id == refdoc_refid
                target = target[0...(target.index '#')]
                id_attr = %( id="xref--#{refdoc_id}")
              else
                id_attr = %( id="xref--#{refdoc_id}--#{refdoc_refid}")
              end
              # ex. chapter-id#
            else
              refdoc_id = refdoc_refid = refid
              # inflate key to spine item root (e.g., transform chapter-id to chapter-id#chapter-id)
              refid = %(#{refid}##{refid})
              id_attr = %( id="xref--#{refdoc_id}")
            end
            id_attr = '' unless @xrefs_seen.add? refid
            refdoc = doc.references[:spine_items].find {|it| refdoc_id == (it.id || (it.attr 'docname')) }
            if refdoc
              if (refs = refdoc.references[:refs]) && ::Asciidoctor::AbstractNode === (ref = refs[refdoc_refid])
                text ||= ::Asciidoctor::Document === ref ? ((ref.attr 'docreftext') || ref.doctitle) : ref.xreftext((@xrefstyle ||= (doc.attr 'xrefstyle')))
              elsif (xreftext = refdoc.references[:ids][refdoc_refid])
                text ||= xreftext
              else
                logger.warn %(#{::File.basename doc.attr('docfile')}: invalid reference to unknown anchor in #{refdoc_id} chapter: #{refdoc_refid})
              end
            else
              logger.warn %(#{::File.basename doc.attr('docfile')}: invalid reference to anchor in unknown chapter: #{refdoc_id})
            end
          else
            id_attr = (@xrefs_seen.add? refid) ? %( id="xref-#{refid}") : ''
            if (refs = doc.references[:refs])
              if ::Asciidoctor::AbstractNode === (ref = refs[refid])
                xreftext = text || ref.xreftext((@xrefstyle ||= (doc.attr 'xrefstyle')))
              end
            else
              xreftext = doc.references[:ids][refid]
            end

            if xreftext
              text ||= xreftext
            else
              # FIXME: we get false negatives for reference to bibref when using Asciidoctor < 1.5.6
              logger.warn %(#{::File.basename doc.attr('docfile')}: invalid reference to unknown local anchor (or valid bibref): #{refid})
            end
          end
          %(<a#{id_attr} href="#{target}" class="xref">#{text || "[#{refid}]"}</a>)
        when :ref
          %(<a id="#{target}"></a>)
        when :link
          %(<a href="#{target}" class="link">#{node.text}</a>)
        when :bibref
          if @xrefs_seen.include? target
            %(<a id="#{target}" href="#xref-#{target}">[#{target}]</a>)
          else
            %(<a id="#{target}"></a>[#{target}])
          end
        end
      end

      def convert_inline_break node
        %(#{node.text}<br/>)
      end

      def convert_inline_button node
        %(<b class="button">[<span class="label">#{node.text}</span>]</b>)
      end

      def convert_inline_callout node
        num = CalloutStartNum
        int_num = node.text.to_i
        (int_num - 1).times { num = num.next }
        %(<i class="conum" data-value="#{int_num}">#{num}</i>)
      end

      def convert_inline_footnote node
        if (index = node.attr 'index')
          %(<sup class="noteref">[<a id="noteref-#{index}" href="#note-#{index}" epub:type="noteref">#{index}</a>]</sup>)
        elsif node.type == :xref
          %(<mark class="noteref" title="Unresolved note reference">#{node.text}</mark>)
        end
      end

      def convert_inline_image node
        if node.type == 'icon'
          @icon_names << (icon_name = node.target)
          i_classes = ['icon', %(i-#{icon_name})]
          i_classes << %(icon-#{node.attr 'size'}) if node.attr? 'size'
          i_classes << %(icon-flip-#{(node.attr 'flip')[0]}) if node.attr? 'flip'
          i_classes << %(icon-rotate-#{node.attr 'rotate'}) if node.attr? 'rotate'
          i_classes << node.role if node.role?
          %(<i class="#{i_classes * ' '}"></i>)
        else
          target = node.image_uri node.target
          register_image node, target

          if target.end_with? '.svg'
            # TODO: make this a convenience method on document
            epub_properties = (node.document.attributes['epub-properties'] ||= [])
            epub_properties << 'svg' unless epub_properties.include? 'svg'
          end

          img_attrs = resolve_image_attrs node
          img_attrs << %(class="inline#{prepend_space node.role}")
          %(<img src="#{target}"#{prepend_space img_attrs * ' '}/>)
        end
      end

      def convert_inline_indexterm node
        node.type == :visible ? node.text : ''
      end

      def convert_inline_kbd node
        if (keys = node.attr 'keys').size == 1
          %(<kbd>#{keys[0]}</kbd>)
        else
          key_combo = keys.map {|key| %(<kbd>#{key}</kbd>) }.join '+'
          %(<span class="keyseq">#{key_combo}</span>)
        end
      end

      def convert_inline_menu node
        menu = node.attr 'menu'
        # NOTE we swap right angle quote with chevron right from FontAwesome using CSS
        caret = %(#{NoBreakSpace}<span class="caret">#{RightAngleQuote}</span> )
        if !(submenus = node.attr 'submenus').empty?
          submenu_path = submenus.map {|submenu| %(<span class="submenu">#{submenu}</span>#{caret}) }.join.chop
          %(<span class="menuseq"><span class="menu">#{menu}</span>#{caret}#{submenu_path} <span class="menuitem">#{node.attr 'menuitem'}</span></span>)
        elsif (menuitem = node.attr 'menuitem')
          %(<span class="menuseq"><span class="menu">#{menu}</span>#{caret}<span class="menuitem">#{menuitem}</span></span>)
        else
          %(<span class="menu">#{menu}</span>)
        end
      end

      def convert_inline_quoted node
        case node.type
        when :strong
          %(<strong>#{node.text}</strong>)
        when :emphasis
          %(<em>#{node.text}</em>)
        when :monospaced, :asciimath, :latexmath
          # TODO: implement proper stem support. See https://github.com/asciidoctor/asciidoctor-epub3/issues/10
          %(<code class="literal">#{node.text}</code>)
        when :double
          #%(&#x201c;#{node.text}&#x201d;)
          %(“#{node.text}”)
        when :single
          #%(&#x2018;#{node.text}&#x2019;)
          %(‘#{node.text}’)
        when :superscript
          %(<sup>#{node.text}</sup>)
        when :subscript
          %(<sub>#{node.text}</sub>)
        else
          node.text
        end
      end

      def output_content node
        node.content_model == :simple ? %(<p>#{node.content}</p>) : node.content
      end

      # FIXME: merge into with xml_sanitize helper
      def xml_sanitize value, target = :attribute
        sanitized = (value.include? '<') ? value.gsub(XmlElementRx, '').strip.tr_s(' ', ' ') : value
        if target == :plain && (sanitized.include? ';')
          sanitized = sanitized.gsub(CharEntityRx) { [$1.to_i].pack 'U*' } if sanitized.include? '&#'
          sanitized = sanitized.gsub FromHtmlSpecialCharsRx, FromHtmlSpecialCharsMap
        elsif target == :attribute
          sanitized = sanitized.gsub '"', '&quot;' if sanitized.include? '"'
        end
        sanitized
      end

      # TODO: make check for last content paragraph a feature of Asciidoctor
      def mark_last_paragraph root
        return unless (last_block = root.blocks[-1])
        last_block = last_block.blocks[-1] while last_block.context == :section && last_block.blocks?
        if last_block.context == :paragraph
          last_block.attributes['role'] = last_block.role? ? %(#{last_block.role} last) : 'last'
        end
        nil
      end

      # Prepend a space to the value if it's non-nil, otherwise return empty string.
      def prepend_space value
        value ? %( #{value}) : ''
      end
    end

    class DocumentIdGenerator
      ReservedIds = %w(cover nav ncx)
      CharRefRx = /&(?:([a-zA-Z][a-zA-Z]+\d{0,2})|#(\d\d\d{0,4})|#x([\da-fA-F][\da-fA-F][\da-fA-F]{0,3}));/
      if defined? __dir__
        InvalidIdCharsRx = /[^\p{Word}]+/
        LeadingDigitRx = /^\p{Nd}/
      else
        InvalidIdCharsRx = /[^[:word:]]+/
        LeadingDigitRx = /^[[:digit:]]/
      end
      class << self
        def generate_id doc, pre = nil, sep = nil
          synthetic = false
          unless (id = doc.id)
            # NOTE we assume pre is a valid ID prefix and that pre and sep only contain valid ID chars
            pre ||= '_'
            sep = sep ? sep.chr : '_'
            if doc.header?
              id = doc.doctitle sanitize: true
              id = id.gsub CharRefRx do
                $1 ? ($1 == 'amp' ? 'and' : sep) : ((d = $2 ? $2.to_i : $3.hex) == 8217 ? '' : ([d].pack 'U*'))
              end if id.include? '&'
              id = id.downcase.gsub InvalidIdCharsRx, sep
              if id.empty?
                id, synthetic = nil, true
              else
                unless sep.empty?
                  if (id = id.tr_s sep, sep).end_with? sep
                    if id == sep
                      id, synthetic = nil, true
                    else
                      id = (id.start_with? sep) ? id[1..-2] : id.chop
                    end
                  elsif id.start_with? sep
                    id = id[1..-1]
                  end
                end
                unless synthetic
                  if pre.empty?
                    id = %(_#{id}) if LeadingDigitRx =~ id
                  elsif !(id.start_with? pre)
                    id = %(#{pre}#{id})
                  end
                end
              end
            elsif (first_section = doc.first_section)
              id = first_section.id
            else
              synthetic = true
            end
            id = %(#{pre}document#{sep}#{doc.object_id}) if synthetic
          end
          logger.error %(chapter uses a reserved ID: #{id}) if !synthetic && (ReservedIds.include? id)
          id
        end
      end
    end

    require_relative 'packager'

    Extensions.register do
      if (document = @document).backend == 'epub3'
        document.attributes['spine'] = ''
        document.set_attribute 'listing-caption', 'Listing'
        # pygments.rb hangs on JRuby for Windows, see https://github.com/asciidoctor/asciidoctor-epub3/issues/253
        if !(::RUBY_ENGINE == 'jruby' && Gem.win_platform?) && (Gem.try_activate 'pygments.rb')
          if document.set_attribute 'source-highlighter', 'pygments'
            document.set_attribute 'pygments-css', 'style'
            document.set_attribute 'pygments-style', 'bw'
          end
        end
        case (ebook_format = document.attributes['ebook-format'])
        when 'epub3', 'kf8'
          # all good
        when 'mobi'
          ebook_format = document.attributes['ebook-format'] = 'kf8'
        else
          # QUESTION should we display a warning?
          ebook_format = document.attributes['ebook-format'] = 'epub3'
        end
        document.attributes[%(ebook-format-#{ebook_format})] = ''
        # Only fire SpineItemProcessor for top-level include directives
        include_processor SpineItemProcessor.new(document)
        treeprocessor do
          process do |doc|
            doc.id = DocumentIdGenerator.generate_id doc, (doc.attr 'idprefix'), (doc.attr 'idseparator')
            nil
          end
        end
      end
    end
  end
end
