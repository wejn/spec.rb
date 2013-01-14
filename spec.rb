#!/usr/bin/env ruby

require 'cgi'
require 'digest/md5'

class Markup
	attr_accessor :layout

	def initialize
		clear
	end

	def ok?
		@errors.empty?
	end

	def errors
		@errors.dup
	end

	def out
		tpl_out = template_replace(@layout, {
			:content => @content.join("\n"),
			:toc => @toc.join("\n"),
			:toc_no_heading => @toc_nh.join("\n"),
			:title => @title,
			:now => escape(@now.to_s),
			:now_numeric => escape(@now.strftime("%Y-%m-%d %H:%M:%S")),
			:filename => @filename,
			})
		unless @code_lang_used
			tpl_out.
				gsub!(/<!-- s:HILITE \{\{\{ -->.*?<!-- e:HILITE \}\}\} -->\s*/m,
					'')
		end
		tpl_out
	end

	REF_LATE_BIND_ST = "\0\0\0\0SPECRB_LATEBIND_REF{{{"
	REF_LATE_BIND_EN = "}}}SPECRB_LATEBIND_REF\0\0\0\0"
	REF_LATE_BIND_SEP = "\0\0\0\0"
	
	def process(file)
		clear
		@filename = File.basename(file.path) #.sub(/\.[^.]{3,4}$/,'')
		@line = 0
		file.each do |ln|
			ln.chomp!
			@line += 1
			type = typeof(ln)
			case type
			when :title
				@title = title(ln)
			when :heading
				flush
				@content << ""
				@content << heading(ln)
			when :list
				cond_switch_state(:list)
				@current << list_item(ln)
			when :def_list
				cond_switch_state(:def_list)
				@current << def_list_item(ln)
			when :end
				flush
			when :text
				cond_switch_state(:text)
				@current << text_line(ln)
			when :code
				cond_switch_state(:code) or @current << code_line(ln)
			when :img
				cond_switch_state(:text)
				@current << img(ln)
			when :comment
			else
				@errors << "Something weird at line: #{@line}"
			end

		end
		flush
		generate_toc
		# resolve late binds, if any
		@content.map! do |ln|
			out = []
			while ln =~ /#{REF_LATE_BIND_ST}(.*?)#{REF_LATE_BIND_SEP}(.*?)#{REF_LATE_BIND_EN}/
				pre, label, url, post = $`, $1, $2, $'
				out << pre
				ao = []
				ids = []
				for level, name, id in @toc_data
					if (name.index(url) || -1).zero?
						ao << "<a href=\"#" + id + "\">" + escape(label) + "</a>"
						ids << id
					end
				end
				case ao.size
				when 0
					@errors << "Undefined reference `#{url}` with label `#{label}`."
					out << escape(label)
				when 1
					out << ao.first
				else
					#@errors << "Multiple references for `#{url}` with label `#{label}`."
					out << [escape(label), "[",
						((1..ids.size).zip(ids).map { |l,i| "<a href=\"##{i}\">#{l}</a>"}).join(', '), "]"].join
				end
				ln = post
			end
			out << ln
			out.join
		end
	end

	private
	def clear
		@content = []
		@toc = []
		@toc_nh = []
		@toc_data = []
		@state = :end
		@errors = []
		@current = []

		@layout ||= DATA.read
		@now = Time.now
		@title = "Unnamed spec ({{{{FILENAME}}}})"
		@filename = "?"
		@heading_base = 1
		@code_lang = nil
		@code_lang_used = false
		@resolve_sections = {}
	end
	
	def template_replace(where, what)
		what.each do |k, v|
			where.gsub!(Regexp.new(Regexp.escape("{{" + "{{#{k.to_s}}}" +
				"}}"), Regexp::IGNORECASE), v.gsub(/\\/, '\\\\\\\\'))
		end
		where
	end

	def title(ln)
		@title = escape(ln.sub(/^!\s+/,''))
	end

	def cond_switch_state(st)
		unless @state == st
			flush
			@state = st
			true
		else
			false
		end
	end

	def generate_toc
		level = 0
		@toc << "<h#{@heading_base + 1}>Table of contents</h#{@heading_base + 1}>"
		(@toc_data + [[0, nil, nil]]).each do |lev, entry, key|
			case level <=> lev
			when -1
				(lev-level).times do |i|
					l = (lev + i - 1)
					if l.zero?
						@toc_nh << (" " * l) + "<ul>"
					else
						@toc_nh << (" " * l) + "<li style='list-style-type: none;'><ul>"
					end
				end
			when 0
				# nothing
			when 1
				(level-lev).times do |i|
					l = (level - i - 1)
					if l.zero?
						@toc_nh << (" " * l) + "</ul>"
					else
						@toc_nh << (" " * l) + "</ul></li>"
					end
				end
			end
			level = lev
			@toc_nh << (" " * lev) + '<li><a href="#' + key + '">' + entry + '</a></li>' unless key.nil? || entry.nil?
		end
		@toc_nh << ""
		@toc += @toc_nh
	end

	def heading(ln)
		ar = ln.split(/^(=+\s+)/)
		if ar.size == 3 && ar[0].empty?
			sz = ar[1].strip.size
			cont = ar[2]
			id = ::Digest::MD5.hexdigest(@toc_data.size.to_s + sz.to_s + cont)
			@toc_data << [sz, ar[2], id]
			"<h#{@heading_base + sz}>" + "<a name='#{id}'></a>" + cont + "</h#{@heading_base + sz}>"
		else
			@errors << "BUG: Heading assertion failed (#{@line})"
			""
		end
	end

	def flush
		case @state
		when :text
			@content << "<p>\n" + @current.join("\n") + "\n</p>"
		when :list
			@content << "<ul>\n" + @current.join("\n") + "\n</ul>"
		when :def_list
			@content << "<dl>\n" + @current.join("\n") + "\n</dl>"
		when :code
			if @code_lang.empty?
				@content << "<pre>\n" + @current.join("\n") + "\n</pre>"
			else
				@content <<
					"<pre class=\"highlight language-#{@code_lang}\">\n" +
					@current.join("\n") + "\n</pre>"
				@code_lang_used = true
			end
		when :end
			# nothing to do ... :)
		else
			@errors << "Some weird state encountered around line: #{@line}"
		end
		@current = []
		@state = :end
	end

	def def_list_item(ln)
		ar = ln.split(/^(:\s*)(.*?)(\s*=\s*)(.*)/)
		if ar.size == 5 && ar[0] == "" && ar[1] =~ /:\s*/ && ar[3] =~ /\s*=\s*/
			"<dt>" + escape(ar[2]) + "</dt>\n<dd>" + escape(ar[4]) + "</dd>"
		else
			@errors << "BUG: Def_list_item assertion failed (#{@line})"
			""
		end
	end

	def text_line(ln)
		out = []
		while (ln =~ /("[^"]*?"|[^\s]*)\<(((ftp|https?|mailto|news|irc|REL|#):|#).*?)\>/)
			pre, label, url, post = $`, $1, $2, $'
			label = label[1..-2] if label =~ /^".*"$/
			url = url[4..-1] if url =~ /^REL:/
			out << escape(pre)
			if url =~ /^#:?/
				url.sub!(/^#:?/, '')
				out << [REF_LATE_BIND_ST,
					label.empty? ? url : label, REF_LATE_BIND_SEP, url,
					REF_LATE_BIND_EN].join
			else
				out << "<a href=\"#{url}\">#{escape(label.empty? ? url : label)}</a>"
			end
			ln = post
		end
		out << escape(ln)
		out.join
	end

	def img(ln)
		ar = ln.split(/\s+/)
		ar.shift
		out = []
		out << "<img src=\"#{ar.first}\""
		ar.shift
		out << "style=\"#{ar.join(' ')}\"" unless ar.join(' ').empty?
		out << "/>"
		out.join(' ')
	end

	def code_line(ln)
		CGI.escapeHTML(ln)
	end

	def list_item(ln)
		ar = ln.split(/^(\*\s+)/)
		if ar.size == 3 && ar[0].empty?
			"<li>" + escape(ar[2]) + "</li>"
		else
			@errors << "BUG: List_item assertion failed (#{@line})"
			""
		end
	end

	def escape(what)
		CGI.escapeHTML(what).
			gsub(/`(.*?)`/) { "<code>" + $1.gsub(/~/, '&#96;') + "</code>" }.
			gsub(/~/, '&nbsp;')
	end

	def typeof(ln)
		if @state == :code
			case ln
			when /^\}\}\}$/
				:end
			else
				:code
			end
		else
			case ln
			when /^!\s+/
				if @content.empty?
					:title
				else
					:text
				end
			when /^=/
				:heading
			when /^\*/
				:list
			when /^:/
				:def_list
			when /^$/, /^\s+$/
				:end
			when /^\{\{\{(.*)/
				@code_lang = $1.strip
				:code
			when /^@/
				:img
			when /^#/
				:comment
			else
				:text
			end
		end
	end
end

if ARGV.size != 1 && ARGV.size != 2
	puts "Usage: #$0 <input_file> [output_file]"
	exit 1
end

begin
	out = ARGV[1].nil? ? $stdout : File.open(ARGV[1], 'w')
rescue
	$stderr.puts "Unable to open output file: #$!"
	exit 1
end

content = []
m = Markup.new

['layout.spec', ARGV[0].gsub(/\.[^.]+$/, '') + '.lsp'].each do |file|
	if FileTest.exists?(file)
		m.layout = File.open(file, 'r').read
		break
	end
end

File.open(ARGV[0]) do |f|
	m.process(f)
end

if m.ok?
	out.puts m.out
	exit 0
else
	$stderr.puts "Error:"
	$stderr.puts m.errors.join("\n")
	exit 1
end
__END__
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
	"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
<head>
<meta http-equiv="content-type" content="text/html; charset=utf-8" />
<title>{{{{TITLE}}}}</title>
<!-- s:HILITE {{{ -->
<!-- github hilite stylesheet -->
<link rel="stylesheet" href="data:text/css;base64,
LyoKCmdpdGh1Yi5jb20gc3R5bGUgKGMpIFZhc2lseSBQb2xvdm55b3YgPHZh
c3RAd2hpdGVhbnRzLm5ldD4KCiovCgpwcmUgY29kZSB7CiAgZGlzcGxheTog
YmxvY2s7IHBhZGRpbmc6IDAuNWVtOwogIGNvbG9yOiAjMDAwOwogIGJhY2tn
cm91bmQ6ICNmOGY4ZmYKfQoKcHJlIC5jb21tZW50LApwcmUgLnRlbXBsYXRl
X2NvbW1lbnQsCnByZSAuZGlmZiAuaGVhZGVyLApwcmUgLmphdmFkb2Mgewog
IGNvbG9yOiAjOTk4OwogIGZvbnQtc3R5bGU6IGl0YWxpYwp9CgpwcmUgLmtl
eXdvcmQsCnByZSAuY3NzIC5ydWxlIC5rZXl3b3JkLApwcmUgLndpbnV0aWxz
LApwcmUgLmphdmFzY3JpcHQgLnRpdGxlLApwcmUgLmxpc3AgLnRpdGxlLApw
cmUgLm5naW54IC50aXRsZSwKcHJlIC5zdWJzdCwKcHJlIC5yZXF1ZXN0LApw
cmUgLnN0YXR1cyB7CiAgY29sb3I6ICMwMDA7CiAgZm9udC13ZWlnaHQ6IGJv
bGQKfQoKcHJlIC5udW1iZXIsCnByZSAuaGV4Y29sb3IgewogIGNvbG9yOiAj
NDBhMDcwCn0KCnByZSAuc3RyaW5nLApwcmUgLnRhZyAudmFsdWUsCnByZSAu
cGhwZG9jLApwcmUgLnRleCAuZm9ybXVsYSB7CiAgY29sb3I6ICNkMTQKfQoK
cHJlIC50aXRsZSwKcHJlIC5pZCB7CiAgY29sb3I6ICM5MDA7CiAgZm9udC13
ZWlnaHQ6IGJvbGQKfQoKcHJlIC5qYXZhc2NyaXB0IC50aXRsZSwKcHJlIC5s
aXNwIC50aXRsZSwKcHJlIC5zdWJzdCB7CiAgZm9udC13ZWlnaHQ6IG5vcm1h
bAp9CgpwcmUgLmNsYXNzIC50aXRsZSwKcHJlIC5oYXNrZWxsIC50eXBlLApw
cmUgLnZoZGwgLmxpdGVyYWwsCnByZSAudGV4IC5jb21tYW5kIHsKICBjb2xv
cjogIzQ1ODsKICBmb250LXdlaWdodDogYm9sZAp9CgpwcmUgLnRhZywKcHJl
IC50YWcgLnRpdGxlLApwcmUgLnJ1bGVzIC5wcm9wZXJ0eSwKcHJlIC5kamFu
Z28gLnRhZyAua2V5d29yZCB7CiAgY29sb3I6ICMwMDAwODA7CiAgZm9udC13
ZWlnaHQ6IG5vcm1hbAp9CgpwcmUgLmF0dHJpYnV0ZSwKcHJlIC52YXJpYWJs
ZSwKcHJlIC5pbnN0YW5jZXZhciwKcHJlIC5saXNwIC5ib2R5IHsKICBjb2xv
cjogIzAwODA4MAp9CgpwcmUgLnJlZ2V4cCB7CiAgY29sb3I6ICMwMDk5MjYK
fQoKcHJlIC5jbGFzcyB7CiAgY29sb3I6ICM0NTg7CiAgZm9udC13ZWlnaHQ6
IGJvbGQKfQoKcHJlIC5zeW1ib2wsCnByZSAucnVieSAuc3ltYm9sIC5zdHJp
bmcsCnByZSAucnVieSAuc3ltYm9sIC5rZXl3b3JkLApwcmUgLnJ1YnkgLnN5
bWJvbCAua2V5bWV0aG9kcywKcHJlIC5saXNwIC5rZXl3b3JkLApwcmUgLnRl
eCAuc3BlY2lhbCwKcHJlIC5pbnB1dF9udW1iZXIgewogIGNvbG9yOiAjOTkw
MDczCn0KCnByZSAuYnVpbHRpbiwKcHJlIC5idWlsdF9pbiwKcHJlIC5saXNw
IC50aXRsZSB7CiAgY29sb3I6ICMwMDg2YjMKfQoKcHJlIC5wcmVwcm9jZXNz
b3IsCnByZSAucGksCnByZSAuZG9jdHlwZSwKcHJlIC5zaGViYW5nLApwcmUg
LmNkYXRhIHsKICBjb2xvcjogIzk5OTsKICBmb250LXdlaWdodDogYm9sZAp9
CgpwcmUgLmRlbGV0aW9uIHsKICBiYWNrZ3JvdW5kOiAjZmRkCn0KCnByZSAu
YWRkaXRpb24gewogIGJhY2tncm91bmQ6ICNkZmQKfQoKcHJlIC5kaWZmIC5j
aGFuZ2UgewogIGJhY2tncm91bmQ6ICMwMDg2YjMKfQoKcHJlIC5jaHVuayB7
CiAgY29sb3I6ICNhYWEKfQoKcHJlIC50ZXggLmZvcm11bGEgewogIG9wYWNp
dHk6IDAuNTsKfQo=" />
<!-- highlight.js -->
<script src="data:text/javascript;base64,
dmFyIGhsanM9bmV3IGZ1bmN0aW9uKCl7ZnVuY3Rpb24gbShwKXtyZXR1cm4g
cC5yZXBsYWNlKC8mL2dtLCImYW1wOyIpLnJlcGxhY2UoLzwvZ20sIiZsdDsi
KX1mdW5jdGlvbiBmKHIscSxwKXtyZXR1cm4gUmVnRXhwKHEsIm0iKyhyLmNJ
PyJpIjoiIikrKHA/ImciOiIiKSl9ZnVuY3Rpb24gYihyKXtmb3IodmFyIHA9
MDtwPHIuY2hpbGROb2Rlcy5sZW5ndGg7cCsrKXt2YXIgcT1yLmNoaWxkTm9k
ZXNbcF07aWYocS5ub2RlTmFtZT09IkNPREUiKXtyZXR1cm4gcX1pZighKHEu
bm9kZVR5cGU9PTMmJnEubm9kZVZhbHVlLm1hdGNoKC9ccysvKSkpe2JyZWFr
fX19ZnVuY3Rpb24gaCh0LHMpe3ZhciBwPSIiO2Zvcih2YXIgcj0wO3I8dC5j
aGlsZE5vZGVzLmxlbmd0aDtyKyspe2lmKHQuY2hpbGROb2Rlc1tyXS5ub2Rl
VHlwZT09Myl7dmFyIHE9dC5jaGlsZE5vZGVzW3JdLm5vZGVWYWx1ZTtpZihz
KXtxPXEucmVwbGFjZSgvXG4vZywiIil9cCs9cX1lbHNle2lmKHQuY2hpbGRO
b2Rlc1tyXS5ub2RlTmFtZT09IkJSIil7cCs9IlxuIn1lbHNle3ArPWgodC5j
aGlsZE5vZGVzW3JdKX19fWlmKC9NU0lFIFs2NzhdLy50ZXN0KG5hdmlnYXRv
ci51c2VyQWdlbnQpKXtwPXAucmVwbGFjZSgvXHIvZywiXG4iKX1yZXR1cm4g
cH1mdW5jdGlvbiBhKHMpe3ZhciByPXMuY2xhc3NOYW1lLnNwbGl0KC9ccysv
KTtyPXIuY29uY2F0KHMucGFyZW50Tm9kZS5jbGFzc05hbWUuc3BsaXQoL1xz
Ky8pKTtmb3IodmFyIHE9MDtxPHIubGVuZ3RoO3ErKyl7dmFyIHA9cltxXS5y
ZXBsYWNlKC9ebGFuZ3VhZ2UtLywiIik7aWYoZVtwXXx8cD09Im5vLWhpZ2hs
aWdodCIpe3JldHVybiBwfX19ZnVuY3Rpb24gYyhyKXt2YXIgcD1bXTsoZnVu
Y3Rpb24gcSh0LHUpe2Zvcih2YXIgcz0wO3M8dC5jaGlsZE5vZGVzLmxlbmd0
aDtzKyspe2lmKHQuY2hpbGROb2Rlc1tzXS5ub2RlVHlwZT09Myl7dSs9dC5j
aGlsZE5vZGVzW3NdLm5vZGVWYWx1ZS5sZW5ndGh9ZWxzZXtpZih0LmNoaWxk
Tm9kZXNbc10ubm9kZU5hbWU9PSJCUiIpe3UrPTF9ZWxzZXtpZih0LmNoaWxk
Tm9kZXNbc10ubm9kZVR5cGU9PTEpe3AucHVzaCh7ZXZlbnQ6InN0YXJ0Iixv
ZmZzZXQ6dSxub2RlOnQuY2hpbGROb2Rlc1tzXX0pO3U9cSh0LmNoaWxkTm9k
ZXNbc10sdSk7cC5wdXNoKHtldmVudDoic3RvcCIsb2Zmc2V0OnUsbm9kZTp0
LmNoaWxkTm9kZXNbc119KX19fX1yZXR1cm4gdX0pKHIsMCk7cmV0dXJuIHB9
ZnVuY3Rpb24gayh5LHcseCl7dmFyIHE9MDt2YXIgej0iIjt2YXIgcz1bXTtm
dW5jdGlvbiB1KCl7aWYoeS5sZW5ndGgmJncubGVuZ3RoKXtpZih5WzBdLm9m
ZnNldCE9d1swXS5vZmZzZXQpe3JldHVybih5WzBdLm9mZnNldDx3WzBdLm9m
ZnNldCk/eTp3fWVsc2V7cmV0dXJuIHdbMF0uZXZlbnQ9PSJzdGFydCI/eTp3
fX1lbHNle3JldHVybiB5Lmxlbmd0aD95Ond9fWZ1bmN0aW9uIHQoRCl7dmFy
IEE9IjwiK0Qubm9kZU5hbWUudG9Mb3dlckNhc2UoKTtmb3IodmFyIEI9MDtC
PEQuYXR0cmlidXRlcy5sZW5ndGg7QisrKXt2YXIgQz1ELmF0dHJpYnV0ZXNb
Ql07QSs9IiAiK0Mubm9kZU5hbWUudG9Mb3dlckNhc2UoKTtpZihDLnZhbHVl
IT09dW5kZWZpbmVkJiZDLnZhbHVlIT09ZmFsc2UmJkMudmFsdWUhPT1udWxs
KXtBKz0nPSInK20oQy52YWx1ZSkrJyInfX1yZXR1cm4gQSsiPiJ9d2hpbGUo
eS5sZW5ndGh8fHcubGVuZ3RoKXt2YXIgdj11KCkuc3BsaWNlKDAsMSlbMF07
eis9bSh4LnN1YnN0cihxLHYub2Zmc2V0LXEpKTtxPXYub2Zmc2V0O2lmKHYu
ZXZlbnQ9PSJzdGFydCIpe3orPXQodi5ub2RlKTtzLnB1c2godi5ub2RlKX1l
bHNle2lmKHYuZXZlbnQ9PSJzdG9wIil7dmFyIHAscj1zLmxlbmd0aDtkb3ty
LS07cD1zW3JdO3orPSgiPC8iK3Aubm9kZU5hbWUudG9Mb3dlckNhc2UoKSsi
PiIpfXdoaWxlKHAhPXYubm9kZSk7cy5zcGxpY2UociwxKTt3aGlsZShyPHMu
bGVuZ3RoKXt6Kz10KHNbcl0pO3IrK319fX1yZXR1cm4geittKHguc3Vic3Ry
KHEpKX1mdW5jdGlvbiBqKCl7ZnVuY3Rpb24gcSh3LHksdSl7aWYody5jb21w
aWxlZCl7cmV0dXJufXZhciBzPVtdO2lmKHcuayl7dmFyIHI9e307ZnVuY3Rp
b24geChELEMpe3ZhciBBPUMuc3BsaXQoIiAiKTtmb3IodmFyIHo9MDt6PEEu
bGVuZ3RoO3orKyl7dmFyIEI9QVt6XS5zcGxpdCgifCIpO3JbQlswXV09W0Qs
QlsxXT9OdW1iZXIoQlsxXSk6MV07cy5wdXNoKEJbMF0pfX13LmxSPWYoeSx3
Lmx8fGhsanMuSVIsdHJ1ZSk7aWYodHlwZW9mIHcuaz09InN0cmluZyIpe3go
ImtleXdvcmQiLHcuayl9ZWxzZXtmb3IodmFyIHYgaW4gdy5rKXtpZighdy5r
Lmhhc093blByb3BlcnR5KHYpKXtjb250aW51ZX14KHYsdy5rW3ZdKX19dy5r
PXJ9aWYoIXUpe2lmKHcuYldLKXt3LmI9IlxcYigiK3Muam9pbigifCIpKyIp
XFxzIn13LmJSPWYoeSx3LmI/dy5iOiJcXEJ8XFxiIik7aWYoIXcuZSYmIXcu
ZVcpe3cuZT0iXFxCfFxcYiJ9aWYody5lKXt3LmVSPWYoeSx3LmUpfX1pZih3
Lmkpe3cuaVI9Zih5LHcuaSl9aWYody5yPT09dW5kZWZpbmVkKXt3LnI9MX1p
Zighdy5jKXt3LmM9W119dy5jb21waWxlZD10cnVlO2Zvcih2YXIgdD0wO3Q8
dy5jLmxlbmd0aDt0Kyspe2lmKHcuY1t0XT09InNlbGYiKXt3LmNbdF09d31x
KHcuY1t0XSx5LGZhbHNlKX1pZih3LnN0YXJ0cyl7cSh3LnN0YXJ0cyx5LGZh
bHNlKX19Zm9yKHZhciBwIGluIGUpe2lmKCFlLmhhc093blByb3BlcnR5KHAp
KXtjb250aW51ZX1xKGVbcF0uZE0sZVtwXSx0cnVlKX19ZnVuY3Rpb24gZChE
LEUpe2lmKCFqLmNhbGxlZCl7aigpO2ouY2FsbGVkPXRydWV9ZnVuY3Rpb24g
cyhyLE8pe2Zvcih2YXIgTj0wO048Ty5jLmxlbmd0aDtOKyspe3ZhciBNPU8u
Y1tOXS5iUi5leGVjKHIpO2lmKE0mJk0uaW5kZXg9PTApe3JldHVybiBPLmNb
Tl19fX1mdW5jdGlvbiB3KE0scil7aWYocFtNXS5lJiZwW01dLmVSLnRlc3Qo
cikpe3JldHVybiAxfWlmKHBbTV0uZVcpe3ZhciBOPXcoTS0xLHIpO3JldHVy
biBOP04rMTowfXJldHVybiAwfWZ1bmN0aW9uIHgocixNKXtyZXR1cm4gTS5p
JiZNLmlSLnRlc3Qocil9ZnVuY3Rpb24gTChPLFApe3ZhciBOPVtdO2Zvcih2
YXIgTT0wO008Ty5jLmxlbmd0aDtNKyspe04ucHVzaChPLmNbTV0uYil9dmFy
IHI9cC5sZW5ndGgtMTtkb3tpZihwW3JdLmUpe04ucHVzaChwW3JdLmUpfXIt
LX13aGlsZShwW3IrMV0uZVcpO2lmKE8uaSl7Ti5wdXNoKE8uaSl9cmV0dXJu
IE4ubGVuZ3RoP2YoUCxOLmpvaW4oInwiKSx0cnVlKTpudWxsfWZ1bmN0aW9u
IHEoTixNKXt2YXIgTz1wW3AubGVuZ3RoLTFdO2lmKE8udD09PXVuZGVmaW5l
ZCl7Ty50PUwoTyxGKX12YXIgcjtpZihPLnQpe08udC5sYXN0SW5kZXg9TTty
PU8udC5leGVjKE4pfXJldHVybiByP1tOLnN1YnN0cihNLHIuaW5kZXgtTSks
clswXSxmYWxzZV06W04uc3Vic3RyKE0pLCIiLHRydWVdfWZ1bmN0aW9uIEEo
TyxyKXt2YXIgTT1GLmNJP3JbMF0udG9Mb3dlckNhc2UoKTpyWzBdO3ZhciBO
PU8ua1tNXTtpZihOJiZOIGluc3RhbmNlb2YgQXJyYXkpe3JldHVybiBOfXJl
dHVybiBmYWxzZX1mdW5jdGlvbiBHKE0sUSl7TT1tKE0pO2lmKCFRLmspe3Jl
dHVybiBNfXZhciByPSIiO3ZhciBQPTA7US5sUi5sYXN0SW5kZXg9MDt2YXIg
Tj1RLmxSLmV4ZWMoTSk7d2hpbGUoTil7cis9TS5zdWJzdHIoUCxOLmluZGV4
LVApO3ZhciBPPUEoUSxOKTtpZihPKXt5Kz1PWzFdO3IrPSc8c3BhbiBjbGFz
cz0iJytPWzBdKyciPicrTlswXSsiPC9zcGFuPiJ9ZWxzZXtyKz1OWzBdfVA9
US5sUi5sYXN0SW5kZXg7Tj1RLmxSLmV4ZWMoTSl9cmV0dXJuIHIrTS5zdWJz
dHIoUCl9ZnVuY3Rpb24gQihNLE4pe3ZhciByO2lmKE4uc0w9PSIiKXtyPWco
TSl9ZWxzZXtyPWQoTi5zTCxNKX1pZihOLnI+MCl7eSs9ci5rZXl3b3JkX2Nv
dW50O0MrPXIucn1yZXR1cm4nPHNwYW4gY2xhc3M9Iicrci5sYW5ndWFnZSsn
Ij4nK3IudmFsdWUrIjwvc3Bhbj4ifWZ1bmN0aW9uIEsocixNKXtpZihNLnNM
JiZlW00uc0xdfHxNLnNMPT0iIil7cmV0dXJuIEIocixNKX1lbHNle3JldHVy
biBHKHIsTSl9fWZ1bmN0aW9uIEooTixyKXt2YXIgTT1OLmNOPyc8c3BhbiBj
bGFzcz0iJytOLmNOKyciPic6IiI7aWYoTi5yQil7eis9TTtOLmJ1ZmZlcj0i
In1lbHNle2lmKE4uZUIpe3orPW0ocikrTTtOLmJ1ZmZlcj0iIn1lbHNle3or
PU07Ti5idWZmZXI9cn19cC5wdXNoKE4pO0MrPU4ucn1mdW5jdGlvbiBIKE8s
TixSKXt2YXIgUz1wW3AubGVuZ3RoLTFdO2lmKFIpe3orPUsoUy5idWZmZXIr
TyxTKTtyZXR1cm4gZmFsc2V9dmFyIFE9cyhOLFMpO2lmKFEpe3orPUsoUy5i
dWZmZXIrTyxTKTtKKFEsTik7cmV0dXJuIFEuckJ9dmFyIE09dyhwLmxlbmd0
aC0xLE4pO2lmKE0pe3ZhciBQPVMuY04/Ijwvc3Bhbj4iOiIiO2lmKFMuckUp
e3orPUsoUy5idWZmZXIrTyxTKStQfWVsc2V7aWYoUy5lRSl7eis9SyhTLmJ1
ZmZlcitPLFMpK1ArbShOKX1lbHNle3orPUsoUy5idWZmZXIrTytOLFMpK1B9
fXdoaWxlKE0+MSl7UD1wW3AubGVuZ3RoLTJdLmNOPyI8L3NwYW4+IjoiIjt6
Kz1QO00tLTtwLmxlbmd0aC0tfXZhciByPXBbcC5sZW5ndGgtMV07cC5sZW5n
dGgtLTtwW3AubGVuZ3RoLTFdLmJ1ZmZlcj0iIjtpZihyLnN0YXJ0cyl7Sihy
LnN0YXJ0cywiIil9cmV0dXJuIFMuckV9aWYoeChOLFMpKXt0aHJvdyJJbGxl
Z2FsIn19dmFyIEY9ZVtEXTt2YXIgcD1bRi5kTV07dmFyIEM9MDt2YXIgeT0w
O3ZhciB6PSIiO3RyeXt2YXIgdCx2PTA7Ri5kTS5idWZmZXI9IiI7ZG97dD1x
KEUsdik7dmFyIHU9SCh0WzBdLHRbMV0sdFsyXSk7dis9dFswXS5sZW5ndGg7
aWYoIXUpe3YrPXRbMV0ubGVuZ3RofX13aGlsZSghdFsyXSk7cmV0dXJue3I6
QyxrZXl3b3JkX2NvdW50OnksdmFsdWU6eixsYW5ndWFnZTpEfX1jYXRjaChJ
KXtpZihJPT0iSWxsZWdhbCIpe3JldHVybntyOjAsa2V5d29yZF9jb3VudDow
LHZhbHVlOm0oRSl9fWVsc2V7dGhyb3cgSX19fWZ1bmN0aW9uIGcodCl7dmFy
IHA9e2tleXdvcmRfY291bnQ6MCxyOjAsdmFsdWU6bSh0KX07dmFyIHI9cDtm
b3IodmFyIHEgaW4gZSl7aWYoIWUuaGFzT3duUHJvcGVydHkocSkpe2NvbnRp
bnVlfXZhciBzPWQocSx0KTtzLmxhbmd1YWdlPXE7aWYocy5rZXl3b3JkX2Nv
dW50K3Mucj5yLmtleXdvcmRfY291bnQrci5yKXtyPXN9aWYocy5rZXl3b3Jk
X2NvdW50K3Mucj5wLmtleXdvcmRfY291bnQrcC5yKXtyPXA7cD1zfX1pZihy
Lmxhbmd1YWdlKXtwLnNlY29uZF9iZXN0PXJ9cmV0dXJuIHB9ZnVuY3Rpb24g
aShyLHEscCl7aWYocSl7cj1yLnJlcGxhY2UoL14oKDxbXj5dKz58XHQpKykv
Z20sZnVuY3Rpb24odCx3LHYsdSl7cmV0dXJuIHcucmVwbGFjZSgvXHQvZyxx
KX0pfWlmKHApe3I9ci5yZXBsYWNlKC9cbi9nLCI8YnI+Iil9cmV0dXJuIHJ9
ZnVuY3Rpb24gbih0LHcscil7dmFyIHg9aCh0LHIpO3ZhciB2PWEodCk7dmFy
IHkscztpZih2PT0ibm8taGlnaGxpZ2h0Iil7cmV0dXJufWlmKHYpe3k9ZCh2
LHgpfWVsc2V7eT1nKHgpO3Y9eS5sYW5ndWFnZX12YXIgcT1jKHQpO2lmKHEu
bGVuZ3RoKXtzPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoInByZSIpO3MuaW5u
ZXJIVE1MPXkudmFsdWU7eS52YWx1ZT1rKHEsYyhzKSx4KX15LnZhbHVlPWko
eS52YWx1ZSx3LHIpO3ZhciB1PXQuY2xhc3NOYW1lO2lmKCF1Lm1hdGNoKCIo
XFxzfF4pKGxhbmd1YWdlLSk/Iit2KyIoXFxzfCQpIikpe3U9dT8odSsiICIr
dik6dn1pZigvTVNJRSBbNjc4XS8udGVzdChuYXZpZ2F0b3IudXNlckFnZW50
KSYmdC50YWdOYW1lPT0iQ09ERSImJnQucGFyZW50Tm9kZS50YWdOYW1lPT0i
UFJFIil7cz10LnBhcmVudE5vZGU7dmFyIHA9ZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgiZGl2Iik7cC5pbm5lckhUTUw9IjxwcmU+PGNvZGU+Iit5LnZhbHVl
KyI8L2NvZGU+PC9wcmU+Ijt0PXAuZmlyc3RDaGlsZC5maXJzdENoaWxkO3Au
Zmlyc3RDaGlsZC5jTj1zLmNOO3MucGFyZW50Tm9kZS5yZXBsYWNlQ2hpbGQo
cC5maXJzdENoaWxkLHMpfWVsc2V7dC5pbm5lckhUTUw9eS52YWx1ZX10LmNs
YXNzTmFtZT11O3QucmVzdWx0PXtsYW5ndWFnZTp2LGt3Onkua2V5d29yZF9j
b3VudCxyZTp5LnJ9O2lmKHkuc2Vjb25kX2Jlc3Qpe3Quc2Vjb25kX2Jlc3Q9
e2xhbmd1YWdlOnkuc2Vjb25kX2Jlc3QubGFuZ3VhZ2Usa3c6eS5zZWNvbmRf
YmVzdC5rZXl3b3JkX2NvdW50LHJlOnkuc2Vjb25kX2Jlc3Qucn19fWZ1bmN0
aW9uIG8oKXtpZihvLmNhbGxlZCl7cmV0dXJufW8uY2FsbGVkPXRydWU7dmFy
IHI9ZG9jdW1lbnQuZ2V0RWxlbWVudHNCeVRhZ05hbWUoInByZSIpO2Zvcih2
YXIgcD0wO3A8ci5sZW5ndGg7cCsrKXt2YXIgcT1iKHJbcF0pO2lmKHEpe24o
cSxobGpzLnRhYlJlcGxhY2UpfX19ZnVuY3Rpb24gbCgpe2lmKHdpbmRvdy5h
ZGRFdmVudExpc3RlbmVyKXt3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigiRE9N
Q29udGVudExvYWRlZCIsbyxmYWxzZSk7d2luZG93LmFkZEV2ZW50TGlzdGVu
ZXIoImxvYWQiLG8sZmFsc2UpfWVsc2V7aWYod2luZG93LmF0dGFjaEV2ZW50
KXt3aW5kb3cuYXR0YWNoRXZlbnQoIm9ubG9hZCIsbyl9ZWxzZXt3aW5kb3cu
b25sb2FkPW99fX12YXIgZT17fTt0aGlzLkxBTkdVQUdFUz1lO3RoaXMuaGln
aGxpZ2h0PWQ7dGhpcy5oaWdobGlnaHRBdXRvPWc7dGhpcy5maXhNYXJrdXA9
aTt0aGlzLmhpZ2hsaWdodEJsb2NrPW47dGhpcy5pbml0SGlnaGxpZ2h0aW5n
PW87dGhpcy5pbml0SGlnaGxpZ2h0aW5nT25Mb2FkPWw7dGhpcy5JUj0iW2Et
ekEtWl1bYS16QS1aMC05X10qIjt0aGlzLlVJUj0iW2EtekEtWl9dW2EtekEt
WjAtOV9dKiI7dGhpcy5OUj0iXFxiXFxkKyhcXC5cXGQrKT8iO3RoaXMuQ05S
PSJcXGIoMFt4WF1bYS1mQS1GMC05XSt8KFxcZCsoXFwuXFxkKik/fFxcLlxc
ZCspKFtlRV1bLStdP1xcZCspPykiO3RoaXMuQk5SPSJcXGIoMGJbMDFdKyki
O3RoaXMuUlNSPSIhfCE9fCE9PXwlfCU9fCZ8JiZ8Jj18XFwqfFxcKj18XFwr
fFxcKz18LHxcXC58LXwtPXwvfC89fDp8O3w8fDw8fDw8PXw8PXw9fD09fD09
PXw+fD49fD4+fD4+PXw+Pj58Pj4+PXxcXD98XFxbfFxce3xcXCh8XFxefFxc
Xj18XFx8fFxcfD18XFx8XFx8fH4iO3RoaXMuQkU9e2I6IlxcXFwuIixyOjB9
O3RoaXMuQVNNPXtjTjoic3RyaW5nIixiOiInIixlOiInIixpOiJcXG4iLGM6
W3RoaXMuQkVdLHI6MH07dGhpcy5RU009e2NOOiJzdHJpbmciLGI6JyInLGU6
JyInLGk6IlxcbiIsYzpbdGhpcy5CRV0scjowfTt0aGlzLkNMQ009e2NOOiJj
b21tZW50IixiOiIvLyIsZToiJCJ9O3RoaXMuQ0JMQ0xNPXtjTjoiY29tbWVu
dCIsYjoiL1xcKiIsZToiXFwqLyJ9O3RoaXMuSENNPXtjTjoiY29tbWVudCIs
YjoiIyIsZToiJCJ9O3RoaXMuTk09e2NOOiJudW1iZXIiLGI6dGhpcy5OUixy
OjB9O3RoaXMuQ05NPXtjTjoibnVtYmVyIixiOnRoaXMuQ05SLHI6MH07dGhp
cy5CTk09e2NOOiJudW1iZXIiLGI6dGhpcy5CTlIscjowfTt0aGlzLmluaGVy
aXQ9ZnVuY3Rpb24ocixzKXt2YXIgcD17fTtmb3IodmFyIHEgaW4gcil7cFtx
XT1yW3FdfWlmKHMpe2Zvcih2YXIgcSBpbiBzKXtwW3FdPXNbcV19fXJldHVy
biBwfX0oKTtobGpzLkxBTkdVQUdFUy5iYXNoPWZ1bmN0aW9uKGEpe3ZhciBm
PSJ0cnVlIGZhbHNlIjt2YXIgYz17Y046InZhcmlhYmxlIixiOiJcXCQoW2Et
ekEtWjAtOV9dKylcXGIifTt2YXIgYj17Y046InZhcmlhYmxlIixiOiJcXCRc
XHsoKFtefV0pfChcXFxcfSkpK1xcfSIsYzpbYS5DTk1dfTt2YXIgZz17Y046
InN0cmluZyIsYjonIicsZTonIicsaToiXFxuIixjOlthLkJFLGMsYl0scjow
fTt2YXIgZD17Y046InN0cmluZyIsYjoiJyIsZToiJyIsYzpbe2I6IicnIn1d
LHI6MH07dmFyIGU9e2NOOiJ0ZXN0X2NvbmRpdGlvbiIsYjoiIixlOiIiLGM6
W2csZCxjLGIsYS5DTk1dLGs6e2xpdGVyYWw6Zn0scjowfTtyZXR1cm57ZE06
e2s6e2tleXdvcmQ6ImlmIHRoZW4gZWxzZSBmaSBmb3IgYnJlYWsgY29udGlu
dWUgd2hpbGUgaW4gZG8gZG9uZSBlY2hvIGV4aXQgcmV0dXJuIHNldCBkZWNs
YXJlIixsaXRlcmFsOmZ9LGM6W3tjTjoic2hlYmFuZyIsYjoiKCMhXFwvYmlu
XFwvYmFzaCl8KCMhXFwvYmluXFwvc2gpIixyOjEwfSxjLGIsYS5IQ00sYS5D
Tk0sZyxkLGEuaW5oZXJpdChlLHtiOiJcXFsgIixlOiIgXFxdIixyOjB9KSxh
LmluaGVyaXQoZSx7YjoiXFxbXFxbICIsZToiIFxcXVxcXSJ9KV19fX0oaGxq
cyk7aGxqcy5MQU5HVUFHRVMuZXJsYW5nPWZ1bmN0aW9uKGkpe3ZhciBjPSJb
YS16J11bYS16QS1aMC05XyddKiI7dmFyIG89IigiK2MrIjoiK2MrInwiK2Mr
IikiO3ZhciBmPXtrZXl3b3JkOiJhZnRlciBhbmQgYW5kYWxzb3wxMCBiYW5k
IGJlZ2luIGJub3QgYm9yIGJzbCBienIgYnhvciBjYXNlIGNhdGNoIGNvbmQg
ZGl2IGVuZCBmdW4gbGV0IG5vdCBvZiBvcmVsc2V8MTAgcXVlcnkgcmVjZWl2
ZSByZW0gdHJ5IHdoZW4geG9yIixsaXRlcmFsOiJmYWxzZSB0cnVlIn07dmFy
IGw9e2NOOiJjb21tZW50IixiOiIlIixlOiIkIixyOjB9O3ZhciBlPXtjTjoi
bnVtYmVyIixiOiJcXGIoXFxkKyNbYS1mQS1GMC05XSt8XFxkKyhcXC5cXGQr
KT8oW2VFXVstK10/XFxkKyk/KSIscjowfTt2YXIgZz17YjoiZnVuXFxzKyIr
YysiL1xcZCsifTt2YXIgbj17YjpvKyJcXCgiLGU6IlxcKSIsckI6dHJ1ZSxy
OjAsYzpbe2NOOiJmdW5jdGlvbl9uYW1lIixiOm8scjowfSx7YjoiXFwoIixl
OiJcXCkiLGVXOnRydWUsckU6dHJ1ZSxyOjB9XX07dmFyIGg9e2NOOiJ0dXBs
ZSIsYjoieyIsZToifSIscjowfTt2YXIgYT17Y046InZhcmlhYmxlIixiOiJc
XGJfKFtBLVpdW0EtWmEtejAtOV9dKik/IixyOjB9O3ZhciBtPXtjTjoidmFy
aWFibGUiLGI6IltBLVpdW2EtekEtWjAtOV9dKiIscjowfTt2YXIgYj17Yjoi
IyIsZToifSIsaToiLiIscjowLHJCOnRydWUsYzpbe2NOOiJyZWNvcmRfbmFt
ZSIsYjoiIyIraS5VSVIscjowfSx7YjoieyIsZVc6dHJ1ZSxyOjB9XX07dmFy
IGs9e2s6ZixiOiIoZnVufHJlY2VpdmV8aWZ8dHJ5fGNhc2UpIixlOiJlbmQi
fTtrLmM9W2wsZyxpLmluaGVyaXQoaS5BU00se2NOOiIifSksayxuLGkuUVNN
LGUsaCxhLG0sYl07dmFyIGo9W2wsZyxrLG4saS5RU00sZSxoLGEsbSxiXTtu
LmNbMV0uYz1qO2guYz1qO2IuY1sxXS5jPWo7dmFyIGQ9e2NOOiJwYXJhbXMi
LGI6IlxcKCIsZToiXFwpIixjOmp9O3JldHVybntkTTp7azpmLGk6Iig8L3xc
XCo9fFxcKz18LT18Lz18L1xcKnxcXCovfFxcKFxcKnxcXCpcXCkpIixjOlt7
Y046ImZ1bmN0aW9uIixiOiJeIitjKyJcXHMqXFwoIixlOiItPiIsckI6dHJ1
ZSxpOiJcXCh8I3wvL3wvXFwqfFxcXFx8OiIsYzpbZCx7Y046InRpdGxlIixi
OmN9XSxzdGFydHM6e2U6Ijt8XFwuIixrOmYsYzpqfX0sbCx7Y046InBwIixi
OiJeLSIsZToiXFwuIixyOjAsZUU6dHJ1ZSxyQjp0cnVlLGw6Ii0iK2kuSVIs
azoiLW1vZHVsZSAtcmVjb3JkIC11bmRlZiAtZXhwb3J0IC1pZmRlZiAtaWZu
ZGVmIC1hdXRob3IgLWNvcHlyaWdodCAtZG9jIC12c24gLWltcG9ydCAtaW5j
bHVkZSAtaW5jbHVkZV9saWIgLWNvbXBpbGUgLWRlZmluZSAtZWxzZSAtZW5k
aWYgLWZpbGUgLWJlaGF2aW91ciAtYmVoYXZpb3IiLGM6W2RdfSxlLGkuUVNN
LGIsYSxtLGhdfX19KGhsanMpO2hsanMuTEFOR1VBR0VTLmNzPWZ1bmN0aW9u
KGEpe3JldHVybntkTTp7azoiYWJzdHJhY3QgYXMgYmFzZSBib29sIGJyZWFr
IGJ5dGUgY2FzZSBjYXRjaCBjaGFyIGNoZWNrZWQgY2xhc3MgY29uc3QgY29u
dGludWUgZGVjaW1hbCBkZWZhdWx0IGRlbGVnYXRlIGRvIGRvdWJsZSBlbHNl
IGVudW0gZXZlbnQgZXhwbGljaXQgZXh0ZXJuIGZhbHNlIGZpbmFsbHkgZml4
ZWQgZmxvYXQgZm9yIGZvcmVhY2ggZ290byBpZiBpbXBsaWNpdCBpbiBpbnQg
aW50ZXJmYWNlIGludGVybmFsIGlzIGxvY2sgbG9uZyBuYW1lc3BhY2UgbmV3
IG51bGwgb2JqZWN0IG9wZXJhdG9yIG91dCBvdmVycmlkZSBwYXJhbXMgcHJp
dmF0ZSBwcm90ZWN0ZWQgcHVibGljIHJlYWRvbmx5IHJlZiByZXR1cm4gc2J5
dGUgc2VhbGVkIHNob3J0IHNpemVvZiBzdGFja2FsbG9jIHN0YXRpYyBzdHJp
bmcgc3RydWN0IHN3aXRjaCB0aGlzIHRocm93IHRydWUgdHJ5IHR5cGVvZiB1
aW50IHVsb25nIHVuY2hlY2tlZCB1bnNhZmUgdXNob3J0IHVzaW5nIHZpcnR1
YWwgdm9sYXRpbGUgdm9pZCB3aGlsZSBhc2NlbmRpbmcgZGVzY2VuZGluZyBm
cm9tIGdldCBncm91cCBpbnRvIGpvaW4gbGV0IG9yZGVyYnkgcGFydGlhbCBz
ZWxlY3Qgc2V0IHZhbHVlIHZhciB3aGVyZSB5aWVsZCIsYzpbe2NOOiJjb21t
ZW50IixiOiIvLy8iLGU6IiQiLHJCOnRydWUsYzpbe2NOOiJ4bWxEb2NUYWci
LGI6Ii8vL3w8IS0tfC0tPiJ9LHtjTjoieG1sRG9jVGFnIixiOiI8Lz8iLGU6
Ij4ifV19LGEuQ0xDTSxhLkNCTENMTSx7Y046InByZXByb2Nlc3NvciIsYjoi
IyIsZToiJCIsazoiaWYgZWxzZSBlbGlmIGVuZGlmIGRlZmluZSB1bmRlZiB3
YXJuaW5nIGVycm9yIGxpbmUgcmVnaW9uIGVuZHJlZ2lvbiBwcmFnbWEgY2hl
Y2tzdW0ifSx7Y046InN0cmluZyIsYjonQCInLGU6JyInLGM6W3tiOiciIid9
XX0sYS5BU00sYS5RU00sYS5DTk1dfX19KGhsanMpO2hsanMuTEFOR1VBR0VT
LnJ1Ynk9ZnVuY3Rpb24oZSl7dmFyIGE9IlthLXpBLVpfXVthLXpBLVowLTlf
XSooXFwhfFxcPyk/Ijt2YXIgaz0iW2EtekEtWl9dXFx3KlshPz1dP3xbLSt+
XVxcQHw8PHw+Pnw9fnw9PT0/fDw9PnxbPD5dPT98XFwqXFwqfFstLyslXiYq
fmB8XXxcXFtcXF09PyI7dmFyIGc9e2tleXdvcmQ6ImFuZCBmYWxzZSB0aGVu
IGRlZmluZWQgbW9kdWxlIGluIHJldHVybiByZWRvIGlmIEJFR0lOIHJldHJ5
IGVuZCBmb3IgdHJ1ZSBzZWxmIHdoZW4gbmV4dCB1bnRpbCBkbyBiZWdpbiB1
bmxlc3MgRU5EIHJlc2N1ZSBuaWwgZWxzZSBicmVhayB1bmRlZiBub3Qgc3Vw
ZXIgY2xhc3MgY2FzZSByZXF1aXJlIHlpZWxkIGFsaWFzIHdoaWxlIGVuc3Vy
ZSBlbHNpZiBvciBkZWYiLGtleW1ldGhvZHM6Il9faWRfXyBfX3NlbmRfXyBh
Ym9ydCBhYnMgYWxsPyBhbGxvY2F0ZSBhbmNlc3RvcnMgYW55PyBhcml0eSBh
c3NvYyBhdCBhdF9leGl0IGF1dG9sb2FkIGF1dG9sb2FkPyBiZXR3ZWVuPyBi
aW5kaW5nIGJpbm1vZGUgYmxvY2tfZ2l2ZW4/IGNhbGwgY2FsbGNjIGNhbGxl
ciBjYXBpdGFsaXplIGNhcGl0YWxpemUhIGNhc2VjbXAgY2F0Y2ggY2VpbCBj
ZW50ZXIgY2hvbXAgY2hvbXAhIGNob3AgY2hvcCEgY2hyIGNsYXNzIGNsYXNz
X2V2YWwgY2xhc3NfdmFyaWFibGVfZGVmaW5lZD8gY2xhc3NfdmFyaWFibGVz
IGNsZWFyIGNsb25lIGNsb3NlIGNsb3NlX3JlYWQgY2xvc2Vfd3JpdGUgY2xv
c2VkPyBjb2VyY2UgY29sbGVjdCBjb2xsZWN0ISBjb21wYWN0IGNvbXBhY3Qh
IGNvbmNhdCBjb25zdF9kZWZpbmVkPyBjb25zdF9nZXQgY29uc3RfbWlzc2lu
ZyBjb25zdF9zZXQgY29uc3RhbnRzIGNvdW50IGNyeXB0IGRlZmF1bHQgZGVm
YXVsdF9wcm9jIGRlbGV0ZSBkZWxldGUhIGRlbGV0ZV9hdCBkZWxldGVfaWYg
ZGV0ZWN0IGRpc3BsYXkgZGl2IGRpdm1vZCBkb3duY2FzZSBkb3duY2FzZSEg
ZG93bnRvIGR1bXAgZHVwIGVhY2ggZWFjaF9ieXRlIGVhY2hfaW5kZXggZWFj
aF9rZXkgZWFjaF9saW5lIGVhY2hfcGFpciBlYWNoX3ZhbHVlIGVhY2hfd2l0
aF9pbmRleCBlbXB0eT8gZW50cmllcyBlb2YgZW9mPyBlcWw/IGVxdWFsPyBl
dmFsIGV4ZWMgZXhpdCBleGl0ISBleHRlbmQgZmFpbCBmY250bCBmZXRjaCBm
aWxlbm8gZmlsbCBmaW5kIGZpbmRfYWxsIGZpcnN0IGZsYXR0ZW4gZmxhdHRl
biEgZmxvb3IgZmx1c2ggZm9yX2ZkIGZvcmVhY2ggZm9yayBmb3JtYXQgZnJl
ZXplIGZyb3plbj8gZnN5bmMgZ2V0YyBnZXRzIGdsb2JhbF92YXJpYWJsZXMg
Z3JlcCBnc3ViIGdzdWIhIGhhc19rZXk/IGhhc192YWx1ZT8gaGFzaCBoZXgg
aWQgaW5jbHVkZSBpbmNsdWRlPyBpbmNsdWRlZF9tb2R1bGVzIGluZGV4IGlu
ZGV4ZXMgaW5kaWNlcyBpbmR1Y2VkX2Zyb20gaW5qZWN0IGluc2VydCBpbnNw
ZWN0IGluc3RhbmNlX2V2YWwgaW5zdGFuY2VfbWV0aG9kIGluc3RhbmNlX21l
dGhvZHMgaW5zdGFuY2Vfb2Y/IGluc3RhbmNlX3ZhcmlhYmxlX2RlZmluZWQ/
IGluc3RhbmNlX3ZhcmlhYmxlX2dldCBpbnN0YW5jZV92YXJpYWJsZV9zZXQg
aW5zdGFuY2VfdmFyaWFibGVzIGludGVnZXI/IGludGVybiBpbnZlcnQgaW9j
dGwgaXNfYT8gaXNhdHR5IGl0ZXJhdG9yPyBqb2luIGtleT8ga2V5cyBraW5k
X29mPyBsYW1iZGEgbGFzdCBsZW5ndGggbGluZW5vIGxqdXN0IGxvYWQgbG9j
YWxfdmFyaWFibGVzIGxvb3AgbHN0cmlwIGxzdHJpcCEgbWFwIG1hcCEgbWF0
Y2ggbWF4IG1lbWJlcj8gbWVyZ2UgbWVyZ2UhIG1ldGhvZCBtZXRob2RfZGVm
aW5lZD8gbWV0aG9kX21pc3NpbmcgbWV0aG9kcyBtaW4gbW9kdWxlX2V2YWwg
bW9kdWxvIG5hbWUgbmVzdGluZyBuZXcgbmV4dCBuZXh0ISBuaWw/IG5pdGVt
cyBub256ZXJvPyBvYmplY3RfaWQgb2N0IG9wZW4gcGFjayBwYXJ0aXRpb24g
cGlkIHBpcGUgcG9wIHBvcGVuIHBvcyBwcmVjIHByZWNfZiBwcmVjX2kgcHJp
bnQgcHJpbnRmIHByaXZhdGVfY2xhc3NfbWV0aG9kIHByaXZhdGVfaW5zdGFu
Y2VfbWV0aG9kcyBwcml2YXRlX21ldGhvZF9kZWZpbmVkPyBwcml2YXRlX21l
dGhvZHMgcHJvYyBwcm90ZWN0ZWRfaW5zdGFuY2VfbWV0aG9kcyBwcm90ZWN0
ZWRfbWV0aG9kX2RlZmluZWQ/IHByb3RlY3RlZF9tZXRob2RzIHB1YmxpY19j
bGFzc19tZXRob2QgcHVibGljX2luc3RhbmNlX21ldGhvZHMgcHVibGljX21l
dGhvZF9kZWZpbmVkPyBwdWJsaWNfbWV0aG9kcyBwdXNoIHB1dGMgcHV0cyBx
dW8gcmFpc2UgcmFuZCByYXNzb2MgcmVhZCByZWFkX25vbmJsb2NrIHJlYWRj
aGFyIHJlYWRsaW5lIHJlYWRsaW5lcyByZWFkcGFydGlhbCByZWhhc2ggcmVq
ZWN0IHJlamVjdCEgcmVtYWluZGVyIHJlb3BlbiByZXBsYWNlIHJlcXVpcmUg
cmVzcG9uZF90bz8gcmV2ZXJzZSByZXZlcnNlISByZXZlcnNlX2VhY2ggcmV3
aW5kIHJpbmRleCByanVzdCByb3VuZCByc3RyaXAgcnN0cmlwISBzY2FuIHNl
ZWsgc2VsZWN0IHNlbmQgc2V0X3RyYWNlX2Z1bmMgc2hpZnQgc2luZ2xldG9u
X21ldGhvZF9hZGRlZCBzaW5nbGV0b25fbWV0aG9kcyBzaXplIHNsZWVwIHNs
aWNlIHNsaWNlISBzb3J0IHNvcnQhIHNvcnRfYnkgc3BsaXQgc3ByaW50ZiBz
cXVlZXplIHNxdWVlemUhIHNyYW5kIHN0YXQgc3RlcCBzdG9yZSBzdHJpcCBz
dHJpcCEgc3ViIHN1YiEgc3VjYyBzdWNjISBzdW0gc3VwZXJjbGFzcyBzd2Fw
Y2FzZSBzd2FwY2FzZSEgc3luYyBzeXNjYWxsIHN5c29wZW4gc3lzcmVhZCBz
eXNzZWVrIHN5c3RlbSBzeXN3cml0ZSB0YWludCB0YWludGVkPyB0ZWxsIHRl
c3QgdGhyb3cgdGltZXMgdG9fYSB0b19hcnkgdG9fZiB0b19oYXNoIHRvX2kg
dG9faW50IHRvX2lvIHRvX3Byb2MgdG9fcyB0b19zdHIgdG9fc3ltIHRyIHRy
ISB0cl9zIHRyX3MhIHRyYWNlX3ZhciB0cmFuc3Bvc2UgdHJhcCB0cnVuY2F0
ZSB0dHk/IHR5cGUgdW5nZXRjIHVuaXEgdW5pcSEgdW5wYWNrIHVuc2hpZnQg
dW50YWludCB1bnRyYWNlX3ZhciB1cGNhc2UgdXBjYXNlISB1cGRhdGUgdXB0
byB2YWx1ZT8gdmFsdWVzIHZhbHVlc19hdCB3YXJuIHdyaXRlIHdyaXRlX25v
bmJsb2NrIHplcm8/IHppcCJ9O3ZhciBjPXtjTjoieWFyZG9jdGFnIixiOiJA
W0EtWmEtel0rIn07dmFyIGw9W3tjTjoiY29tbWVudCIsYjoiIyIsZToiJCIs
YzpbY119LHtjTjoiY29tbWVudCIsYjoiXlxcPWJlZ2luIixlOiJeXFw9ZW5k
IixjOltjXSxyOjEwfSx7Y046ImNvbW1lbnQiLGI6Il5fX0VORF9fIixlOiJc
XG4kIn1dO3ZhciBkPXtjTjoic3Vic3QiLGI6IiNcXHsiLGU6In0iLGw6YSxr
Omd9O3ZhciBqPVtlLkJFLGRdO3ZhciBiPVt7Y046InN0cmluZyIsYjoiJyIs
ZToiJyIsYzpqLHI6MH0se2NOOiJzdHJpbmciLGI6JyInLGU6JyInLGM6aixy
OjB9LHtjTjoic3RyaW5nIixiOiIlW3F3XT9cXCgiLGU6IlxcKSIsYzpqfSx7
Y046InN0cmluZyIsYjoiJVtxd10/XFxbIixlOiJcXF0iLGM6an0se2NOOiJz
dHJpbmciLGI6IiVbcXddP3siLGU6In0iLGM6an0se2NOOiJzdHJpbmciLGI6
IiVbcXddPzwiLGU6Ij4iLGM6aixyOjEwfSx7Y046InN0cmluZyIsYjoiJVtx
d10/LyIsZToiLyIsYzpqLHI6MTB9LHtjTjoic3RyaW5nIixiOiIlW3F3XT8l
IixlOiIlIixjOmoscjoxMH0se2NOOiJzdHJpbmciLGI6IiVbcXddPy0iLGU6
Ii0iLGM6aixyOjEwfSx7Y046InN0cmluZyIsYjoiJVtxd10/XFx8IixlOiJc
XHwiLGM6aixyOjEwfV07dmFyIGk9e2NOOiJmdW5jdGlvbiIsYjoiXFxiZGVm
XFxzKyIsZToiIHwkfDsiLGw6YSxrOmcsYzpbe2NOOiJ0aXRsZSIsYjprLGw6
YSxrOmd9LHtjTjoicGFyYW1zIixiOiJcXCgiLGU6IlxcKSIsbDphLGs6Z31d
LmNvbmNhdChsKX07dmFyIGg9e2NOOiJpZGVudGlmaWVyIixiOmEsbDphLGs6
ZyxyOjB9O3ZhciBmPWwuY29uY2F0KGIuY29uY2F0KFt7Y046ImNsYXNzIixi
V0s6dHJ1ZSxlOiIkfDsiLGs6ImNsYXNzIG1vZHVsZSIsYzpbe2NOOiJ0aXRs
ZSIsYjoiW0EtWmEtel9dXFx3Kig6OlxcdyspKihcXD98XFwhKT8iLHI6MH0s
e2NOOiJpbmhlcml0YW5jZSIsYjoiPFxccyoiLGM6W3tjTjoicGFyZW50Iixi
OiIoIitlLklSKyI6Oik/IitlLklSfV19XS5jb25jYXQobCl9LGkse2NOOiJj
b25zdGFudCIsYjoiKDo6KT8oW0EtWl1cXHcqKDo6KT8pKyIscjowfSx7Y046
InN5bWJvbCIsYjoiOiIsYzpiLmNvbmNhdChbaF0pLHI6MH0se2NOOiJudW1i
ZXIiLGI6IihcXGIwWzAtN19dKyl8KFxcYjB4WzAtOWEtZkEtRl9dKyl8KFxc
YlsxLTldWzAtOV9dKihcXC5bMC05X10rKT8pfFswX11cXGIiLHI6MH0se2NO
OiJudW1iZXIiLGI6IlxcP1xcdyJ9LHtjTjoidmFyaWFibGUiLGI6IihcXCRc
XFcpfCgoXFwkfFxcQFxcQD8pKFxcdyspKSJ9LGgse2I6IigiK2UuUlNSKyIp
XFxzKiIsYzpsLmNvbmNhdChbe2NOOiJyZWdleHAiLGI6Ii8iLGU6Ii9bYS16
XSoiLGk6IlxcbiIsYzpbZS5CRV19XSkscjowfV0pKTtkLmM9ZjtpLmNbMV0u
Yz1mO3JldHVybntkTTp7bDphLGs6ZyxjOmZ9fX0oaGxqcyk7aGxqcy5MQU5H
VUFHRVMuZGlmZj1mdW5jdGlvbihhKXtyZXR1cm57Y0k6dHJ1ZSxkTTp7Yzpb
e2NOOiJjaHVuayIsYjoiXlxcQFxcQCArXFwtXFxkKyxcXGQrICtcXCtcXGQr
LFxcZCsgK1xcQFxcQCQiLHI6MTB9LHtjTjoiY2h1bmsiLGI6Il5cXCpcXCpc
XCogK1xcZCssXFxkKyArXFwqXFwqXFwqXFwqJCIscjoxMH0se2NOOiJjaHVu
ayIsYjoiXlxcLVxcLVxcLSArXFxkKyxcXGQrICtcXC1cXC1cXC1cXC0kIixy
OjEwfSx7Y046ImhlYWRlciIsYjoiSW5kZXg6ICIsZToiJCJ9LHtjTjoiaGVh
ZGVyIixiOiI9PT09PSIsZToiPT09PT0kIn0se2NOOiJoZWFkZXIiLGI6Il5c
XC1cXC1cXC0iLGU6IiQifSx7Y046ImhlYWRlciIsYjoiXlxcKnszfSAiLGU6
IiQifSx7Y046ImhlYWRlciIsYjoiXlxcK1xcK1xcKyIsZToiJCJ9LHtjTjoi
aGVhZGVyIixiOiJcXCp7NX0iLGU6IlxcKns1fSQifSx7Y046ImFkZGl0aW9u
IixiOiJeXFwrIixlOiIkIn0se2NOOiJkZWxldGlvbiIsYjoiXlxcLSIsZToi
JCJ9LHtjTjoiY2hhbmdlIixiOiJeXFwhIixlOiIkIn1dfX19KGhsanMpO2hs
anMuTEFOR1VBR0VTLmphdmFzY3JpcHQ9ZnVuY3Rpb24oYSl7cmV0dXJue2RN
OntrOntrZXl3b3JkOiJpbiBpZiBmb3Igd2hpbGUgZmluYWxseSB2YXIgbmV3
IGZ1bmN0aW9uIGRvIHJldHVybiB2b2lkIGVsc2UgYnJlYWsgY2F0Y2ggaW5z
dGFuY2VvZiB3aXRoIHRocm93IGNhc2UgZGVmYXVsdCB0cnkgdGhpcyBzd2l0
Y2ggY29udGludWUgdHlwZW9mIGRlbGV0ZSIsbGl0ZXJhbDoidHJ1ZSBmYWxz
ZSBudWxsIHVuZGVmaW5lZCBOYU4gSW5maW5pdHkifSxjOlthLkFTTSxhLlFT
TSxhLkNMQ00sYS5DQkxDTE0sYS5DTk0se2I6IigiK2EuUlNSKyJ8XFxiKGNh
c2V8cmV0dXJufHRocm93KVxcYilcXHMqIixrOiJyZXR1cm4gdGhyb3cgY2Fz
ZSIsYzpbYS5DTENNLGEuQ0JMQ0xNLHtjTjoicmVnZXhwIixiOiIvIixlOiIv
W2dpbV0qIixjOlt7YjoiXFxcXC8ifV19XSxyOjB9LHtjTjoiZnVuY3Rpb24i
LGJXSzp0cnVlLGU6InsiLGs6ImZ1bmN0aW9uIixjOlt7Y046InRpdGxlIixi
OiJbQS1aYS16JF9dWzAtOUEtWmEteiRfXSoifSx7Y046InBhcmFtcyIsYjoi
XFwoIixlOiJcXCkiLGM6W2EuQ0xDTSxhLkNCTENMTV0saToiW1wiJ1xcKF0i
fV0saToiXFxbfCUifV19fX0oaGxqcyk7aGxqcy5MQU5HVUFHRVMuY3NzPWZ1
bmN0aW9uKGEpe3ZhciBiPXtjTjoiZnVuY3Rpb24iLGI6YS5JUisiXFwoIixl
OiJcXCkiLGM6W3tlVzp0cnVlLGVFOnRydWUsYzpbYS5OTSxhLkFTTSxhLlFT
TV19XX07cmV0dXJue2NJOnRydWUsZE06e2k6Ils9L3wnXSIsYzpbYS5DQkxD
TE0se2NOOiJpZCIsYjoiXFwjW0EtWmEtejAtOV8tXSsifSx7Y046ImNsYXNz
IixiOiJcXC5bQS1aYS16MC05Xy1dKyIscjowfSx7Y046ImF0dHJfc2VsZWN0
b3IiLGI6IlxcWyIsZToiXFxdIixpOiIkIn0se2NOOiJwc2V1ZG8iLGI6Ijoo
Oik/W2EtekEtWjAtOVxcX1xcLVxcK1xcKFxcKVxcXCJcXCddKyJ9LHtjTjoi
YXRfcnVsZSIsYjoiQChmb250LWZhY2V8cGFnZSkiLGw6IlthLXotXSsiLGs6
ImZvbnQtZmFjZSBwYWdlIn0se2NOOiJhdF9ydWxlIixiOiJAIixlOiJbeztd
IixlRTp0cnVlLGs6ImltcG9ydCBwYWdlIG1lZGlhIGNoYXJzZXQiLGM6W2Is
YS5BU00sYS5RU00sYS5OTV19LHtjTjoidGFnIixiOmEuSVIscjowfSx7Y046
InJ1bGVzIixiOiJ7IixlOiJ9IixpOiJbXlxcc10iLHI6MCxjOlthLkNCTENM
TSx7Y046InJ1bGUiLGI6IlteXFxzXSIsckI6dHJ1ZSxlOiI7IixlVzp0cnVl
LGM6W3tjTjoiYXR0cmlidXRlIixiOiJbQS1aXFxfXFwuXFwtXSsiLGU6Ijoi
LGVFOnRydWUsaToiW15cXHNdIixzdGFydHM6e2NOOiJ2YWx1ZSIsZVc6dHJ1
ZSxlRTp0cnVlLGM6W2IsYS5OTSxhLlFTTSxhLkFTTSxhLkNCTENMTSx7Y046
ImhleGNvbG9yIixiOiJcXCNbMC05QS1GXSsifSx7Y046ImltcG9ydGFudCIs
YjoiIWltcG9ydGFudCJ9XX19XX1dfV19fX0oaGxqcyk7aGxqcy5MQU5HVUFH
RVMueG1sPWZ1bmN0aW9uKGEpe3ZhciBjPSJbQS1aYS16MC05XFwuXzotXSsi
O3ZhciBiPXtlVzp0cnVlLGM6W3tjTjoiYXR0cmlidXRlIixiOmMscjowfSx7
YjonPSInLHJCOnRydWUsZTonIicsYzpbe2NOOiJ2YWx1ZSIsYjonIicsZVc6
dHJ1ZX1dfSx7YjoiPSciLHJCOnRydWUsZToiJyIsYzpbe2NOOiJ2YWx1ZSIs
YjoiJyIsZVc6dHJ1ZX1dfSx7YjoiPSIsYzpbe2NOOiJ2YWx1ZSIsYjoiW15c
XHMvPl0rIn1dfV19O3JldHVybntjSTp0cnVlLGRNOntjOlt7Y046InBpIixi
OiI8XFw/IixlOiJcXD8+IixyOjEwfSx7Y046ImRvY3R5cGUiLGI6IjwhRE9D
VFlQRSIsZToiPiIscjoxMCxjOlt7YjoiXFxbIixlOiJcXF0ifV19LHtjTjoi
Y29tbWVudCIsYjoiPCEtLSIsZToiLS0+IixyOjEwfSx7Y046ImNkYXRhIixi
OiI8XFwhXFxbQ0RBVEFcXFsiLGU6IlxcXVxcXT4iLHI6MTB9LHtjTjoidGFn
IixiOiI8c3R5bGUoPz1cXHN8PnwkKSIsZToiPiIsazp7dGl0bGU6InN0eWxl
In0sYzpbYl0sc3RhcnRzOntlOiI8L3N0eWxlPiIsckU6dHJ1ZSxzTDoiY3Nz
In19LHtjTjoidGFnIixiOiI8c2NyaXB0KD89XFxzfD58JCkiLGU6Ij4iLGs6
e3RpdGxlOiJzY3JpcHQifSxjOltiXSxzdGFydHM6e2U6IjxcL3NjcmlwdD4i
LHJFOnRydWUsc0w6ImphdmFzY3JpcHQifX0se2I6IjwlIixlOiIlPiIsc0w6
InZic2NyaXB0In0se2NOOiJ0YWciLGI6IjwvPyIsZToiLz8+IixjOlt7Y046
InRpdGxlIixiOiJbXiAvPl0rIn0sYl19XX19fShobGpzKTtobGpzLkxBTkdV
QUdFUy5odHRwPWZ1bmN0aW9uKGEpe3JldHVybntkTTp7aToiXFxTIixjOlt7
Y046InN0YXR1cyIsYjoiXkhUVFAvWzAtOVxcLl0rIixlOiIkIixjOlt7Y046
Im51bWJlciIsYjoiXFxiXFxkezN9XFxiIn1dfSx7Y046InJlcXVlc3QiLGI6
Il5bQS1aXSsgKC4qPykgSFRUUC9bMC05XFwuXSskIixyQjp0cnVlLGU6IiQi
LGM6W3tjTjoic3RyaW5nIixiOiIgIixlOiIgIixlQjp0cnVlLGVFOnRydWV9
XX0se2NOOiJhdHRyaWJ1dGUiLGI6Il5cXHciLGU6IjogIixlRTp0cnVlLGk6
IlxcbiIsc3RhcnRzOntjTjoic3RyaW5nIixlOiIkIn19LHtiOiJcXG5cXG4i
LHN0YXJ0czp7c0w6IiIsZVc6dHJ1ZX19XX19fShobGpzKTtobGpzLkxBTkdV
QUdFUy5qYXZhPWZ1bmN0aW9uKGEpe3JldHVybntkTTp7azoiZmFsc2Ugc3lu
Y2hyb25pemVkIGludCBhYnN0cmFjdCBmbG9hdCBwcml2YXRlIGNoYXIgYm9v
bGVhbiBzdGF0aWMgbnVsbCBpZiBjb25zdCBmb3IgdHJ1ZSB3aGlsZSBsb25n
IHRocm93IHN0cmljdGZwIGZpbmFsbHkgcHJvdGVjdGVkIGltcG9ydCBuYXRp
dmUgZmluYWwgcmV0dXJuIHZvaWQgZW51bSBlbHNlIGJyZWFrIHRyYW5zaWVu
dCBuZXcgY2F0Y2ggaW5zdGFuY2VvZiBieXRlIHN1cGVyIHZvbGF0aWxlIGNh
c2UgYXNzZXJ0IHNob3J0IHBhY2thZ2UgZGVmYXVsdCBkb3VibGUgcHVibGlj
IHRyeSB0aGlzIHN3aXRjaCBjb250aW51ZSB0aHJvd3MiLGM6W3tjTjoiamF2
YWRvYyIsYjoiL1xcKlxcKiIsZToiXFwqLyIsYzpbe2NOOiJqYXZhZG9jdGFn
IixiOiJAW0EtWmEtel0rIn1dLHI6MTB9LGEuQ0xDTSxhLkNCTENMTSxhLkFT
TSxhLlFTTSx7Y046ImNsYXNzIixiV0s6dHJ1ZSxlOiJ7IixrOiJjbGFzcyBp
bnRlcmZhY2UiLGk6IjoiLGM6W3tiV0s6dHJ1ZSxrOiJleHRlbmRzIGltcGxl
bWVudHMiLHI6MTB9LHtjTjoidGl0bGUiLGI6YS5VSVJ9XX0sYS5DTk0se2NO
OiJhbm5vdGF0aW9uIixiOiJAW0EtWmEtel0rIn1dfX19KGhsanMpO2hsanMu
TEFOR1VBR0VTLnBocD1mdW5jdGlvbihhKXt2YXIgZT17Y046InZhcmlhYmxl
IixiOiJcXCQrW2EtekEtWl9ceDdmLVx4ZmZdW2EtekEtWjAtOV9ceDdmLVx4
ZmZdKiJ9O3ZhciBiPVthLmluaGVyaXQoYS5BU00se2k6bnVsbH0pLGEuaW5o
ZXJpdChhLlFTTSx7aTpudWxsfSkse2NOOiJzdHJpbmciLGI6J2IiJyxlOici
JyxjOlthLkJFXX0se2NOOiJzdHJpbmciLGI6ImInIixlOiInIixjOlthLkJF
XX1dO3ZhciBjPVthLkNOTSxhLkJOTV07dmFyIGQ9e2NOOiJ0aXRsZSIsYjph
LlVJUn07cmV0dXJue2NJOnRydWUsZE06e2s6ImFuZCBpbmNsdWRlX29uY2Ug
bGlzdCBhYnN0cmFjdCBnbG9iYWwgcHJpdmF0ZSBlY2hvIGludGVyZmFjZSBh
cyBzdGF0aWMgZW5kc3dpdGNoIGFycmF5IG51bGwgaWYgZW5kd2hpbGUgb3Ig
Y29uc3QgZm9yIGVuZGZvcmVhY2ggc2VsZiB2YXIgd2hpbGUgaXNzZXQgcHVi
bGljIHByb3RlY3RlZCBleGl0IGZvcmVhY2ggdGhyb3cgZWxzZWlmIGluY2x1
ZGUgX19GSUxFX18gZW1wdHkgcmVxdWlyZV9vbmNlIGRvIHhvciByZXR1cm4g
aW1wbGVtZW50cyBwYXJlbnQgY2xvbmUgdXNlIF9fQ0xBU1NfXyBfX0xJTkVf
XyBlbHNlIGJyZWFrIHByaW50IGV2YWwgbmV3IGNhdGNoIF9fTUVUSE9EX18g
Y2FzZSBleGNlcHRpb24gcGhwX3VzZXJfZmlsdGVyIGRlZmF1bHQgZGllIHJl
cXVpcmUgX19GVU5DVElPTl9fIGVuZGRlY2xhcmUgZmluYWwgdHJ5IHRoaXMg
c3dpdGNoIGNvbnRpbnVlIGVuZGZvciBlbmRpZiBkZWNsYXJlIHVuc2V0IHRy
dWUgZmFsc2UgbmFtZXNwYWNlIHRyYWl0IGdvdG8gaW5zdGFuY2VvZiBpbnN0
ZWFkb2YgX19ESVJfXyBfX05BTUVTUEFDRV9fIF9faGFsdF9jb21waWxlciIs
YzpbYS5DTENNLGEuSENNLHtjTjoiY29tbWVudCIsYjoiL1xcKiIsZToiXFwq
LyIsYzpbe2NOOiJwaHBkb2MiLGI6Ilxcc0BbQS1aYS16XSsifV19LHtjTjoi
Y29tbWVudCIsZUI6dHJ1ZSxiOiJfX2hhbHRfY29tcGlsZXIuKz87IixlVzp0
cnVlfSx7Y046InN0cmluZyIsYjoiPDw8WydcIl0/XFx3K1snXCJdPyQiLGU6
Il5cXHcrOyIsYzpbYS5CRV19LHtjTjoicHJlcHJvY2Vzc29yIixiOiI8XFw/
cGhwIixyOjEwfSx7Y046InByZXByb2Nlc3NvciIsYjoiXFw/PiJ9LGUse2NO
OiJmdW5jdGlvbiIsYldLOnRydWUsZToieyIsazoiZnVuY3Rpb24iLGk6Ilxc
JHxcXFt8JSIsYzpbZCx7Y046InBhcmFtcyIsYjoiXFwoIixlOiJcXCkiLGM6
WyJzZWxmIixlLGEuQ0JMQ0xNXS5jb25jYXQoYikuY29uY2F0KGMpfV19LHtj
TjoiY2xhc3MiLGJXSzp0cnVlLGU6InsiLGs6ImNsYXNzIixpOiJbOlxcKFxc
JF0iLGM6W3tiV0s6dHJ1ZSxlVzp0cnVlLGs6ImV4dGVuZHMiLGM6W2RdfSxk
XX0se2I6Ij0+In1dLmNvbmNhdChiKS5jb25jYXQoYyl9fX0oaGxqcyk7aGxq
cy5MQU5HVUFHRVMuaGFza2VsbD1mdW5jdGlvbihhKXt2YXIgZD17Y046InR5
cGUiLGI6IlxcYltBLVpdW1xcdyddKiIscjowfTt2YXIgYz17Y046ImNvbnRh
aW5lciIsYjoiXFwoIixlOiJcXCkiLGM6W3tjTjoidHlwZSIsYjoiXFxiW0Et
Wl1bXFx3XSooXFwoKFxcLlxcLnwsfFxcdyspXFwpKT8ifSx7Y046InRpdGxl
IixiOiJbX2Etel1bXFx3J10qIn1dfTt2YXIgYj17Y046ImNvbnRhaW5lciIs
YjoieyIsZToifSIsYzpjLmN9O3JldHVybntkTTp7azoibGV0IGluIGlmIHRo
ZW4gZWxzZSBjYXNlIG9mIHdoZXJlIGRvIG1vZHVsZSBpbXBvcnQgaGlkaW5n
IHF1YWxpZmllZCB0eXBlIGRhdGEgbmV3dHlwZSBkZXJpdmluZyBjbGFzcyBp
bnN0YW5jZSBub3QgYXMgZm9yZWlnbiBjY2FsbCBzYWZlIHVuc2FmZSIsYzpb
e2NOOiJjb21tZW50IixiOiItLSIsZToiJCJ9LHtjTjoicHJlcHJvY2Vzc29y
IixiOiJ7LSMiLGU6IiMtfSJ9LHtjTjoiY29tbWVudCIsYzpbInNlbGYiXSxi
OiJ7LSIsZToiLX0ifSx7Y046InN0cmluZyIsYjoiXFxzKyciLGU6IiciLGM6
W2EuQkVdLHI6MH0sYS5RU00se2NOOiJpbXBvcnQiLGI6IlxcYmltcG9ydCIs
ZToiJCIsazoiaW1wb3J0IHF1YWxpZmllZCBhcyBoaWRpbmciLGM6W2NdLGk6
IlxcV1xcLnw7In0se2NOOiJtb2R1bGUiLGI6IlxcYm1vZHVsZSIsZToid2hl
cmUiLGs6Im1vZHVsZSB3aGVyZSIsYzpbY10saToiXFxXXFwufDsifSx7Y046
ImNsYXNzIixiOiJcXGIoY2xhc3N8aW5zdGFuY2UpIixlOiJ3aGVyZSIsazoi
Y2xhc3Mgd2hlcmUgaW5zdGFuY2UiLGM6W2RdfSx7Y046InR5cGVkZWYiLGI6
IlxcYihkYXRhfChuZXcpP3R5cGUpIixlOiIkIixrOiJkYXRhIHR5cGUgbmV3
dHlwZSBkZXJpdmluZyIsYzpbZCxjLGJdfSxhLkNOTSx7Y046InNoZWJhbmci
LGI6IiMhXFwvdXNyXFwvYmluXFwvZW52IHJ1bmhhc2tlbGwiLGU6IiQifSxk
LHtjTjoidGl0bGUiLGI6Il5bX2Etel1bXFx3J10qIn1dfX19KGhsanMpO2hs
anMuTEFOR1VBR0VTLnRleD1mdW5jdGlvbihhKXt2YXIgZD17Y046ImNvbW1h
bmQiLGI6IlxcXFxbYS16QS1a0LAt0Y/QkC3Rj10rW1xcKl0/In07dmFyIGM9
e2NOOiJjb21tYW5kIixiOiJcXFxcW15hLXpBLVrQsC3Rj9CQLdGPMC05XSJ9
O3ZhciBiPXtjTjoic3BlY2lhbCIsYjoiW3t9XFxbXFxdXFwmI35dIixyOjB9
O3JldHVybntkTTp7Yzpbe2I6IlxcXFxbYS16QS1a0LAt0Y/QkC3Rj10rW1xc
Kl0/ICo9ICotP1xcZCpcXC4/XFxkKyhwdHxwY3xtbXxjbXxpbnxkZHxjY3xl
eHxlbSk/IixyQjp0cnVlLGM6W2QsYyx7Y046Im51bWJlciIsYjoiICo9Iixl
OiItP1xcZCpcXC4/XFxkKyhwdHxwY3xtbXxjbXxpbnxkZHxjY3xleHxlbSk/
IixlQjp0cnVlfV0scjoxMH0sZCxjLGIse2NOOiJmb3JtdWxhIixiOiJcXCRc
XCQiLGU6IlxcJFxcJCIsYzpbZCxjLGJdLHI6MH0se2NOOiJmb3JtdWxhIixi
OiJcXCQiLGU6IlxcJCIsYzpbZCxjLGJdLHI6MH0se2NOOiJjb21tZW50Iixi
OiIlIixlOiIkIixyOjB9XX19fShobGpzKTtobGpzLkxBTkdVQUdFUy5zcWw9
ZnVuY3Rpb24oYSl7cmV0dXJue2NJOnRydWUsZE06e2k6IlteXFxzXSIsYzpb
e2NOOiJvcGVyYXRvciIsYjoiKGJlZ2lufHN0YXJ0fGNvbW1pdHxyb2xsYmFj
a3xzYXZlcG9pbnR8bG9ja3xhbHRlcnxjcmVhdGV8ZHJvcHxyZW5hbWV8Y2Fs
bHxkZWxldGV8ZG98aGFuZGxlcnxpbnNlcnR8bG9hZHxyZXBsYWNlfHNlbGVj
dHx0cnVuY2F0ZXx1cGRhdGV8c2V0fHNob3d8cHJhZ21hfGdyYW50KVxcYiIs
ZToiOyIsZVc6dHJ1ZSxrOntrZXl3b3JkOiJhbGwgcGFydGlhbCBnbG9iYWwg
bW9udGggY3VycmVudF90aW1lc3RhbXAgdXNpbmcgZ28gcmV2b2tlIHNtYWxs
aW50IGluZGljYXRvciBlbmQtZXhlYyBkaXNjb25uZWN0IHpvbmUgd2l0aCBj
aGFyYWN0ZXIgYXNzZXJ0aW9uIHRvIGFkZCBjdXJyZW50X3VzZXIgdXNhZ2Ug
aW5wdXQgbG9jYWwgYWx0ZXIgbWF0Y2ggY29sbGF0ZSByZWFsIHRoZW4gcm9s
bGJhY2sgZ2V0IHJlYWQgdGltZXN0YW1wIHNlc3Npb25fdXNlciBub3QgaW50
ZWdlciBiaXQgdW5pcXVlIGRheSBtaW51dGUgZGVzYyBpbnNlcnQgZXhlY3V0
ZSBsaWtlIGlsaWtlfDIgbGV2ZWwgZGVjaW1hbCBkcm9wIGNvbnRpbnVlIGlz
b2xhdGlvbiBmb3VuZCB3aGVyZSBjb25zdHJhaW50cyBkb21haW4gcmlnaHQg
bmF0aW9uYWwgc29tZSBtb2R1bGUgdHJhbnNhY3Rpb24gcmVsYXRpdmUgc2Vj
b25kIGNvbm5lY3QgZXNjYXBlIGNsb3NlIHN5c3RlbV91c2VyIGZvciBkZWZl
cnJlZCBzZWN0aW9uIGNhc3QgY3VycmVudCBzcWxzdGF0ZSBhbGxvY2F0ZSBp
bnRlcnNlY3QgZGVhbGxvY2F0ZSBudW1lcmljIHB1YmxpYyBwcmVzZXJ2ZSBm
dWxsIGdvdG8gaW5pdGlhbGx5IGFzYyBubyBrZXkgb3V0cHV0IGNvbGxhdGlv
biBncm91cCBieSB1bmlvbiBzZXNzaW9uIGJvdGggbGFzdCBsYW5ndWFnZSBj
b25zdHJhaW50IGNvbHVtbiBvZiBzcGFjZSBmb3JlaWduIGRlZmVycmFibGUg
cHJpb3IgY29ubmVjdGlvbiB1bmtub3duIGFjdGlvbiBjb21taXQgdmlldyBv
ciBmaXJzdCBpbnRvIGZsb2F0IHllYXIgcHJpbWFyeSBjYXNjYWRlZCBleGNl
cHQgcmVzdHJpY3Qgc2V0IHJlZmVyZW5jZXMgbmFtZXMgdGFibGUgb3V0ZXIg
b3BlbiBzZWxlY3Qgc2l6ZSBhcmUgcm93cyBmcm9tIHByZXBhcmUgZGlzdGlu
Y3QgbGVhZGluZyBjcmVhdGUgb25seSBuZXh0IGlubmVyIGF1dGhvcml6YXRp
b24gc2NoZW1hIGNvcnJlc3BvbmRpbmcgb3B0aW9uIGRlY2xhcmUgcHJlY2lz
aW9uIGltbWVkaWF0ZSBlbHNlIHRpbWV6b25lX21pbnV0ZSBleHRlcm5hbCB2
YXJ5aW5nIHRyYW5zbGF0aW9uIHRydWUgY2FzZSBleGNlcHRpb24gam9pbiBo
b3VyIGRlZmF1bHQgZG91YmxlIHNjcm9sbCB2YWx1ZSBjdXJzb3IgZGVzY3Jp
cHRvciB2YWx1ZXMgZGVjIGZldGNoIHByb2NlZHVyZSBkZWxldGUgYW5kIGZh
bHNlIGludCBpcyBkZXNjcmliZSBjaGFyIGFzIGF0IGluIHZhcmNoYXIgbnVs
bCB0cmFpbGluZyBhbnkgYWJzb2x1dGUgY3VycmVudF90aW1lIGVuZCBncmFu
dCBwcml2aWxlZ2VzIHdoZW4gY3Jvc3MgY2hlY2sgd3JpdGUgY3VycmVudF9k
YXRlIHBhZCBiZWdpbiB0ZW1wb3JhcnkgZXhlYyB0aW1lIHVwZGF0ZSBjYXRh
bG9nIHVzZXIgc3FsIGRhdGUgb24gaWRlbnRpdHkgdGltZXpvbmVfaG91ciBu
YXR1cmFsIHdoZW5ldmVyIGludGVydmFsIHdvcmsgb3JkZXIgY2FzY2FkZSBk
aWFnbm9zdGljcyBuY2hhciBoYXZpbmcgbGVmdCBjYWxsIGRvIGhhbmRsZXIg
bG9hZCByZXBsYWNlIHRydW5jYXRlIHN0YXJ0IGxvY2sgc2hvdyBwcmFnbWEi
LGFnZ3JlZ2F0ZToiY291bnQgc3VtIG1pbiBtYXggYXZnIn0sYzpbe2NOOiJz
dHJpbmciLGI6IiciLGU6IiciLGM6W2EuQkUse2I6IicnIn1dLHI6MH0se2NO
OiJzdHJpbmciLGI6JyInLGU6JyInLGM6W2EuQkUse2I6JyIiJ31dLHI6MH0s
e2NOOiJzdHJpbmciLGI6ImAiLGU6ImAiLGM6W2EuQkVdfSxhLkNOTV19LGEu
Q0JMQ0xNLHtjTjoiY29tbWVudCIsYjoiLS0iLGU6IiQifV19fX0oaGxqcyk7
aGxqcy5MQU5HVUFHRVMuaW5pPWZ1bmN0aW9uKGEpe3JldHVybntjSTp0cnVl
LGRNOntpOiJbXlxcc10iLGM6W3tjTjoiY29tbWVudCIsYjoiOyIsZToiJCJ9
LHtjTjoidGl0bGUiLGI6Il5cXFsiLGU6IlxcXSJ9LHtjTjoic2V0dGluZyIs
YjoiXlthLXowLTlfXFxbXFxdXStbIFxcdF0qPVsgXFx0XSoiLGU6IiQiLGM6
W3tjTjoidmFsdWUiLGVXOnRydWUsazoib24gb2ZmIHRydWUgZmFsc2UgeWVz
IG5vIixjOlthLlFTTSxhLk5NXX1dfV19fX0oaGxqcyk7aGxqcy5MQU5HVUFH
RVMuY29mZmVlc2NyaXB0PWZ1bmN0aW9uKGUpe3ZhciBkPXtrZXl3b3JkOiJp
biBpZiBmb3Igd2hpbGUgZmluYWxseSBuZXcgZG8gcmV0dXJuIGVsc2UgYnJl
YWsgY2F0Y2ggaW5zdGFuY2VvZiB0aHJvdyB0cnkgdGhpcyBzd2l0Y2ggY29u
dGludWUgdHlwZW9mIGRlbGV0ZSBkZWJ1Z2dlciBjbGFzcyBleHRlbmRzIHN1
cGVydGhlbiB1bmxlc3MgdW50aWwgbG9vcCBvZiBieSB3aGVuIGFuZCBvciBp
cyBpc250IG5vdCIsbGl0ZXJhbDoidHJ1ZSBmYWxzZSBudWxsIHVuZGVmaW5l
ZCB5ZXMgbm8gb24gb2ZmICIscmVzZXJ2ZWQ6ImNhc2UgZGVmYXVsdCBmdW5j
dGlvbiB2YXIgdm9pZCB3aXRoIGNvbnN0IGxldCBlbnVtIGV4cG9ydCBpbXBv
cnQgbmF0aXZlIF9faGFzUHJvcCBfX2V4dGVuZHMgX19zbGljZSBfX2JpbmQg
X19pbmRleE9mIn07dmFyIGE9IltBLVphLXokX11bMC05QS1aYS16JF9dKiI7
dmFyIGg9e2NOOiJzdWJzdCIsYjoiI1xceyIsZToifSIsazpkLGM6W2UuQ05N
LGUuQk5NXX07dmFyIGI9e2NOOiJzdHJpbmciLGI6JyInLGU6JyInLHI6MCxj
OltlLkJFLGhdfTt2YXIgaj17Y046InN0cmluZyIsYjonIiIiJyxlOiciIiIn
LGM6W2UuQkUsaF19O3ZhciBmPXtjTjoiY29tbWVudCIsYjoiIyMjIixlOiIj
IyMifTt2YXIgZz17Y046InJlZ2V4cCIsYjoiLy8vIixlOiIvLy8iLGM6W2Uu
SENNXX07dmFyIGk9e2NOOiJmdW5jdGlvbiIsYjphKyJcXHMqPVxccyooXFwo
LitcXCkpP1xccypbLT1dPiIsckI6dHJ1ZSxjOlt7Y046InRpdGxlIixiOmF9
LHtjTjoicGFyYW1zIixiOiJcXCgiLGU6IlxcKSJ9XX07dmFyIGM9e2I6ImAi
LGU6ImAiLGVCOnRydWUsZUU6dHJ1ZSxzTDoiamF2YXNjcmlwdCJ9O3JldHVy
bntkTTp7azpkLGM6W2UuQ05NLGUuQk5NLGUuQVNNLGosYixmLGUuSENNLGcs
YyxpXX19fShobGpzKTtobGpzLkxBTkdVQUdFU1siZXJsYW5nLXJlcGwiXT1m
dW5jdGlvbihhKXtyZXR1cm57ZE06e2s6e3NwZWNpYWxfZnVuY3Rpb25zOiJz
cGF3biBzcGF3bl9saW5rIHNlbGYiLHJlc2VydmVkOiJhZnRlciBhbmQgYW5k
YWxzb3wxMCBiYW5kIGJlZ2luIGJub3QgYm9yIGJzbCBic3IgYnhvciBjYXNl
IGNhdGNoIGNvbmQgZGl2IGVuZCBmdW4gaWYgbGV0IG5vdCBvZiBvciBvcmVs
c2V8MTAgcXVlcnkgcmVjZWl2ZSByZW0gdHJ5IHdoZW4geG9yIn0sYzpbe2NO
OiJpbnB1dF9udW1iZXIiLGI6Il5bMC05XSs+ICIscjoxMH0se2NOOiJjb21t
ZW50IixiOiIlIixlOiIkIn0se2NOOiJudW1iZXIiLGI6IlxcYihcXGQrI1th
LWZBLUYwLTldK3xcXGQrKFxcLlxcZCspPyhbZUVdWy0rXT9cXGQrKT8pIixy
OjB9LGEuQVNNLGEuUVNNLHtjTjoiY29uc3RhbnQiLGI6IlxcPyg6Oik/KFtB
LVpdXFx3Kig6Oik/KSsifSx7Y046ImFycm93IixiOiItPiJ9LHtjTjoib2si
LGI6Im9rIn0se2NOOiJleGNsYW1hdGlvbl9tYXJrIixiOiIhIn0se2NOOiJm
dW5jdGlvbl9vcl9hdG9tIixiOiIoXFxiW2EteiddW2EtekEtWjAtOV8nXSo6
W2EteiddW2EtekEtWjAtOV8nXSopfChcXGJbYS16J11bYS16QS1aMC05Xydd
KikiLHI6MH0se2NOOiJ2YXJpYWJsZSIsYjoiW0EtWl1bYS16QS1aMC05Xydd
KiIscjowfV19fX0oaGxqcyk7aGxqcy5MQU5HVUFHRVMuanNvbj1mdW5jdGlv
bihhKXt2YXIgZT17bGl0ZXJhbDoidHJ1ZSBmYWxzZSBudWxsIn07dmFyIGQ9
W2EuUVNNLGEuQ05NXTt2YXIgYz17Y046InZhbHVlIixlOiIsIixlVzp0cnVl
LGVFOnRydWUsYzpkLGs6ZX07dmFyIGI9e2I6InsiLGU6In0iLGM6W3tjTjoi
YXR0cmlidXRlIixiOidcXHMqIicsZTonIlxccyo6XFxzKicsZUI6dHJ1ZSxl
RTp0cnVlLGM6W2EuQkVdLGk6IlxcbiIsc3RhcnRzOmN9XSxpOiJcXFMifTt2
YXIgZj17YjoiXFxbIixlOiJcXF0iLGM6W2EuaW5oZXJpdChjLHtjTjpudWxs
fSldLGk6IlxcUyJ9O2Quc3BsaWNlKGQubGVuZ3RoLDAsYixmKTtyZXR1cm57
ZE06e2M6ZCxrOmUsaToiXFxTIn19fShobGpzKTtobGpzLkxBTkdVQUdFUy5j
cHA9ZnVuY3Rpb24oYSl7dmFyIGI9e2tleXdvcmQ6ImZhbHNlIGludCBmbG9h
dCB3aGlsZSBwcml2YXRlIGNoYXIgY2F0Y2ggZXhwb3J0IHZpcnR1YWwgb3Bl
cmF0b3Igc2l6ZW9mIGR5bmFtaWNfY2FzdHwxMCB0eXBlZGVmIGNvbnN0X2Nh
c3R8MTAgY29uc3Qgc3RydWN0IGZvciBzdGF0aWNfY2FzdHwxMCB1bmlvbiBu
YW1lc3BhY2UgdW5zaWduZWQgbG9uZyB0aHJvdyB2b2xhdGlsZSBzdGF0aWMg
cHJvdGVjdGVkIGJvb2wgdGVtcGxhdGUgbXV0YWJsZSBpZiBwdWJsaWMgZnJp
ZW5kIGRvIHJldHVybiBnb3RvIGF1dG8gdm9pZCBlbnVtIGVsc2UgYnJlYWsg
bmV3IGV4dGVybiB1c2luZyB0cnVlIGNsYXNzIGFzbSBjYXNlIHR5cGVpZCBz
aG9ydCByZWludGVycHJldF9jYXN0fDEwIGRlZmF1bHQgZG91YmxlIHJlZ2lz
dGVyIGV4cGxpY2l0IHNpZ25lZCB0eXBlbmFtZSB0cnkgdGhpcyBzd2l0Y2gg
Y29udGludWUgd2NoYXJfdCBpbmxpbmUgZGVsZXRlIGFsaWdub2YgY2hhcjE2
X3QgY2hhcjMyX3QgY29uc3RleHByIGRlY2x0eXBlIG5vZXhjZXB0IG51bGxw
dHIgc3RhdGljX2Fzc2VydCB0aHJlYWRfbG9jYWwgcmVzdHJpY3QgX0Jvb2wg
Y29tcGxleCIsYnVpbHRfaW46InN0ZCBzdHJpbmcgY2luIGNvdXQgY2VyciBj
bG9nIHN0cmluZ3N0cmVhbSBpc3RyaW5nc3RyZWFtIG9zdHJpbmdzdHJlYW0g
YXV0b19wdHIgZGVxdWUgbGlzdCBxdWV1ZSBzdGFjayB2ZWN0b3IgbWFwIHNl
dCBiaXRzZXQgbXVsdGlzZXQgbXVsdGltYXAgdW5vcmRlcmVkX3NldCB1bm9y
ZGVyZWRfbWFwIHVub3JkZXJlZF9tdWx0aXNldCB1bm9yZGVyZWRfbXVsdGlt
YXAgYXJyYXkgc2hhcmVkX3B0ciJ9O3JldHVybntkTTp7azpiLGk6IjwvIixj
OlthLkNMQ00sYS5DQkxDTE0sYS5RU00se2NOOiJzdHJpbmciLGI6IidcXFxc
Py4iLGU6IiciLGk6Ii4ifSx7Y046Im51bWJlciIsYjoiXFxiKFxcZCsoXFwu
XFxkKik/fFxcLlxcZCspKHV8VXxsfEx8dWx8VUx8ZnxGKSJ9LGEuQ05NLHtj
TjoicHJlcHJvY2Vzc29yIixiOiIjIixlOiIkIn0se2NOOiJzdGxfY29udGFp
bmVyIixiOiJcXGIoZGVxdWV8bGlzdHxxdWV1ZXxzdGFja3x2ZWN0b3J8bWFw
fHNldHxiaXRzZXR8bXVsdGlzZXR8bXVsdGltYXB8dW5vcmRlcmVkX21hcHx1
bm9yZGVyZWRfc2V0fHVub3JkZXJlZF9tdWx0aXNldHx1bm9yZGVyZWRfbXVs
dGltYXB8YXJyYXkpXFxzKjwiLGU6Ij4iLGs6YixyOjEwLGM6WyJzZWxmIl19
XX19fShobGpzKTs="></script>
<script type="text/javascript">
window.onload = function() {
	// jQuery: $(function(){ $('pre.highlight').each(function(i, e) {hljs.highlightBlock(e)}); });
	var objects = document.evaluate('//pre[contains(@class, "highlight")]', document, null, XPathResult.UNORDERED_NODE_SNAPSHOT_TYPE, null);
	for (var i = 0; i < objects.snapshotLength; i++) {
		hljs.highlightBlock(objects.snapshotItem(i));
	}
};
</script>
<!-- e:HILITE }}} -->
<style type="text/css">
/* <![CDATA[ */

/* Based on Pixy's (wellstyled.com) style */

/* layout */

body {
	font-family: "Trebuchet MS", sans-serif;
	line-height: 1.5;
	text-align: center;
	margin-top: 0;
	padding: 0;
}

a:link { color: #FF8000; font-weight:bold; }
a:visited { color: #BF8F5F; }
a:hover { background-color:#6291CA; color:white; }

.main {
	width: 800px;
	background-color: #eee;
	padding: 0;
	margin: 0;
	margin-left: auto;
	margin-right: auto;
	text-align: left;
	padding-left: 0.5em;
	padding-right: 0.5em;
}

/* content */

.content code {
	background-color: #ddd;
	white-space: nowrap;
}

.content em {
	color: #f00;
}

.content h2 {
	border-bottom: 3px dashed #0df;
}

.content h3 {
	border-bottom: 2px dashed #0df;
}

.content h4 {
	border-bottom: 1px dashed #0df;
}

.content pre {
	background-color: #ddd;
}

/* header and footer */

.header, .footer {
	font-size: 70%;
	text-align: center;
	font-weight: bold;
}

.header {
	border-bottom: 1px dashed black;
	margin-top: 0;
}

.footer {
	border-top: 1px dashed black;
	margin-bottom: 0;
}

/* toc */

.toc {
	border-bottom: 1px dashed black;
	text-align: left;
	margin-top: 0;
}

/* title */

.title h1 {
	text-align: center;
}

.title {
	border-bottom: 1px dashed black;
	margin-bottom: 1em;
	margin-top: 1em;
}

/* ]]> */
</style>
</head>
<body>
<div class="main">
<div class="header">Generated by spec.rb at: {{{{NOW}}}}</div>

<div class="title"><h1>{{{{TITLE}}}}</h1></div>

<div class="toc">
{{{{TOC}}}}
</div>

<div class="content">
{{{{CONTENT}}}}
</div>

<div class="footer">Generated by spec.rb at: {{{{NOW}}}}</div>
</div>
</body>
</html>
