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
		out << " alt=\"image\" />"
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
XX19fShobGpzKTs=" type="text/javascript"></script>
<!-- e:HILITE }}} -->
<!-- jQuery 1.7.2 min {{{ -->
<script src="data:text/javascript;base64,
LyohIGpRdWVyeSB2MS43LjIganF1ZXJ5LmNvbSB8IGpxdWVyeS5vcmcvbGljZW5zZSAqLwooZnVu
Y3Rpb24oYSxiKXtmdW5jdGlvbiBjeShhKXtyZXR1cm4gZi5pc1dpbmRvdyhhKT9hOmEubm9kZVR5
cGU9PT05P2EuZGVmYXVsdFZpZXd8fGEucGFyZW50V2luZG93OiExfWZ1bmN0aW9uIGN1KGEpe2lm
KCFjalthXSl7dmFyIGI9Yy5ib2R5LGQ9ZigiPCIrYSsiPiIpLmFwcGVuZFRvKGIpLGU9ZC5jc3Mo
ImRpc3BsYXkiKTtkLnJlbW92ZSgpO2lmKGU9PT0ibm9uZSJ8fGU9PT0iIil7Y2t8fChjaz1jLmNy
ZWF0ZUVsZW1lbnQoImlmcmFtZSIpLGNrLmZyYW1lQm9yZGVyPWNrLndpZHRoPWNrLmhlaWdodD0w
KSxiLmFwcGVuZENoaWxkKGNrKTtpZighY2x8fCFjay5jcmVhdGVFbGVtZW50KWNsPShjay5jb250
ZW50V2luZG93fHxjay5jb250ZW50RG9jdW1lbnQpLmRvY3VtZW50LGNsLndyaXRlKChmLnN1cHBv
cnQuYm94TW9kZWw/IjwhZG9jdHlwZSBodG1sPiI6IiIpKyI8aHRtbD48Ym9keT4iKSxjbC5jbG9z
ZSgpO2Q9Y2wuY3JlYXRlRWxlbWVudChhKSxjbC5ib2R5LmFwcGVuZENoaWxkKGQpLGU9Zi5jc3Mo
ZCwiZGlzcGxheSIpLGIucmVtb3ZlQ2hpbGQoY2spfWNqW2FdPWV9cmV0dXJuIGNqW2FdfWZ1bmN0
aW9uIGN0KGEsYil7dmFyIGM9e307Zi5lYWNoKGNwLmNvbmNhdC5hcHBseShbXSxjcC5zbGljZSgw
LGIpKSxmdW5jdGlvbigpe2NbdGhpc109YX0pO3JldHVybiBjfWZ1bmN0aW9uIGNzKCl7Y3E9Yn1m
dW5jdGlvbiBjcigpe3NldFRpbWVvdXQoY3MsMCk7cmV0dXJuIGNxPWYubm93KCl9ZnVuY3Rpb24g
Y2koKXt0cnl7cmV0dXJuIG5ldyBhLkFjdGl2ZVhPYmplY3QoIk1pY3Jvc29mdC5YTUxIVFRQIil9
Y2F0Y2goYil7fX1mdW5jdGlvbiBjaCgpe3RyeXtyZXR1cm4gbmV3IGEuWE1MSHR0cFJlcXVlc3R9
Y2F0Y2goYil7fX1mdW5jdGlvbiBjYihhLGMpe2EuZGF0YUZpbHRlciYmKGM9YS5kYXRhRmlsdGVy
KGMsYS5kYXRhVHlwZSkpO3ZhciBkPWEuZGF0YVR5cGVzLGU9e30sZyxoLGk9ZC5sZW5ndGgsaixr
PWRbMF0sbCxtLG4sbyxwO2ZvcihnPTE7ZzxpO2crKyl7aWYoZz09PTEpZm9yKGggaW4gYS5jb252
ZXJ0ZXJzKXR5cGVvZiBoPT0ic3RyaW5nIiYmKGVbaC50b0xvd2VyQ2FzZSgpXT1hLmNvbnZlcnRl
cnNbaF0pO2w9ayxrPWRbZ107aWYoaz09PSIqIilrPWw7ZWxzZSBpZihsIT09IioiJiZsIT09ayl7
bT1sKyIgIitrLG49ZVttXXx8ZVsiKiAiK2tdO2lmKCFuKXtwPWI7Zm9yKG8gaW4gZSl7aj1vLnNw
bGl0KCIgIik7aWYoalswXT09PWx8fGpbMF09PT0iKiIpe3A9ZVtqWzFdKyIgIitrXTtpZihwKXtv
PWVbb10sbz09PSEwP249cDpwPT09ITAmJihuPW8pO2JyZWFrfX19fSFuJiYhcCYmZi5lcnJvcigi
Tm8gY29udmVyc2lvbiBmcm9tICIrbS5yZXBsYWNlKCIgIiwiIHRvICIpKSxuIT09ITAmJihjPW4/
bihjKTpwKG8oYykpKX19cmV0dXJuIGN9ZnVuY3Rpb24gY2EoYSxjLGQpe3ZhciBlPWEuY29udGVu
dHMsZj1hLmRhdGFUeXBlcyxnPWEucmVzcG9uc2VGaWVsZHMsaCxpLGosaztmb3IoaSBpbiBnKWkg
aW4gZCYmKGNbZ1tpXV09ZFtpXSk7d2hpbGUoZlswXT09PSIqIilmLnNoaWZ0KCksaD09PWImJiho
PWEubWltZVR5cGV8fGMuZ2V0UmVzcG9uc2VIZWFkZXIoImNvbnRlbnQtdHlwZSIpKTtpZihoKWZv
cihpIGluIGUpaWYoZVtpXSYmZVtpXS50ZXN0KGgpKXtmLnVuc2hpZnQoaSk7YnJlYWt9aWYoZlsw
XWluIGQpaj1mWzBdO2Vsc2V7Zm9yKGkgaW4gZCl7aWYoIWZbMF18fGEuY29udmVydGVyc1tpKyIg
IitmWzBdXSl7aj1pO2JyZWFrfWt8fChrPWkpfWo9anx8a31pZihqKXtqIT09ZlswXSYmZi51bnNo
aWZ0KGopO3JldHVybiBkW2pdfX1mdW5jdGlvbiBiXyhhLGIsYyxkKXtpZihmLmlzQXJyYXkoYikp
Zi5lYWNoKGIsZnVuY3Rpb24oYixlKXtjfHxiRC50ZXN0KGEpP2QoYSxlKTpiXyhhKyJbIisodHlw
ZW9mIGU9PSJvYmplY3QiP2I6IiIpKyJdIixlLGMsZCl9KTtlbHNlIGlmKCFjJiZmLnR5cGUoYik9
PT0ib2JqZWN0Iilmb3IodmFyIGUgaW4gYiliXyhhKyJbIitlKyJdIixiW2VdLGMsZCk7ZWxzZSBk
KGEsYil9ZnVuY3Rpb24gYiQoYSxjKXt2YXIgZCxlLGc9Zi5hamF4U2V0dGluZ3MuZmxhdE9wdGlv
bnN8fHt9O2ZvcihkIGluIGMpY1tkXSE9PWImJigoZ1tkXT9hOmV8fChlPXt9KSlbZF09Y1tkXSk7
ZSYmZi5leHRlbmQoITAsYSxlKX1mdW5jdGlvbiBiWihhLGMsZCxlLGYsZyl7Zj1mfHxjLmRhdGFU
eXBlc1swXSxnPWd8fHt9LGdbZl09ITA7dmFyIGg9YVtmXSxpPTAsaj1oP2gubGVuZ3RoOjAsaz1h
PT09YlMsbDtmb3IoO2k8aiYmKGt8fCFsKTtpKyspbD1oW2ldKGMsZCxlKSx0eXBlb2YgbD09InN0
cmluZyImJigha3x8Z1tsXT9sPWI6KGMuZGF0YVR5cGVzLnVuc2hpZnQobCksbD1iWihhLGMsZCxl
LGwsZykpKTsoa3x8IWwpJiYhZ1siKiJdJiYobD1iWihhLGMsZCxlLCIqIixnKSk7cmV0dXJuIGx9
ZnVuY3Rpb24gYlkoYSl7cmV0dXJuIGZ1bmN0aW9uKGIsYyl7dHlwZW9mIGIhPSJzdHJpbmciJiYo
Yz1iLGI9IioiKTtpZihmLmlzRnVuY3Rpb24oYykpe3ZhciBkPWIudG9Mb3dlckNhc2UoKS5zcGxp
dChiTyksZT0wLGc9ZC5sZW5ndGgsaCxpLGo7Zm9yKDtlPGc7ZSsrKWg9ZFtlXSxqPS9eXCsvLnRl
c3QoaCksaiYmKGg9aC5zdWJzdHIoMSl8fCIqIiksaT1hW2hdPWFbaF18fFtdLGlbaj8idW5zaGlm
dCI6InB1c2giXShjKX19fWZ1bmN0aW9uIGJCKGEsYixjKXt2YXIgZD1iPT09IndpZHRoIj9hLm9m
ZnNldFdpZHRoOmEub2Zmc2V0SGVpZ2h0LGU9Yj09PSJ3aWR0aCI/MTowLGc9NDtpZihkPjApe2lm
KGMhPT0iYm9yZGVyIilmb3IoO2U8ZztlKz0yKWN8fChkLT1wYXJzZUZsb2F0KGYuY3NzKGEsInBh
ZGRpbmciK2J4W2VdKSl8fDApLGM9PT0ibWFyZ2luIj9kKz1wYXJzZUZsb2F0KGYuY3NzKGEsYyti
eFtlXSkpfHwwOmQtPXBhcnNlRmxvYXQoZi5jc3MoYSwiYm9yZGVyIitieFtlXSsiV2lkdGgiKSl8
fDA7cmV0dXJuIGQrInB4In1kPWJ5KGEsYik7aWYoZDwwfHxkPT1udWxsKWQ9YS5zdHlsZVtiXTtp
ZihidC50ZXN0KGQpKXJldHVybiBkO2Q9cGFyc2VGbG9hdChkKXx8MDtpZihjKWZvcig7ZTxnO2Ur
PTIpZCs9cGFyc2VGbG9hdChmLmNzcyhhLCJwYWRkaW5nIitieFtlXSkpfHwwLGMhPT0icGFkZGlu
ZyImJihkKz1wYXJzZUZsb2F0KGYuY3NzKGEsImJvcmRlciIrYnhbZV0rIldpZHRoIikpfHwwKSxj
PT09Im1hcmdpbiImJihkKz1wYXJzZUZsb2F0KGYuY3NzKGEsYytieFtlXSkpfHwwKTtyZXR1cm4g
ZCsicHgifWZ1bmN0aW9uIGJvKGEpe3ZhciBiPWMuY3JlYXRlRWxlbWVudCgiZGl2Iik7YmguYXBw
ZW5kQ2hpbGQoYiksYi5pbm5lckhUTUw9YS5vdXRlckhUTUw7cmV0dXJuIGIuZmlyc3RDaGlsZH1m
dW5jdGlvbiBibihhKXt2YXIgYj0oYS5ub2RlTmFtZXx8IiIpLnRvTG93ZXJDYXNlKCk7Yj09PSJp
bnB1dCI/Ym0oYSk6YiE9PSJzY3JpcHQiJiZ0eXBlb2YgYS5nZXRFbGVtZW50c0J5VGFnTmFtZSE9
InVuZGVmaW5lZCImJmYuZ3JlcChhLmdldEVsZW1lbnRzQnlUYWdOYW1lKCJpbnB1dCIpLGJtKX1m
dW5jdGlvbiBibShhKXtpZihhLnR5cGU9PT0iY2hlY2tib3gifHxhLnR5cGU9PT0icmFkaW8iKWEu
ZGVmYXVsdENoZWNrZWQ9YS5jaGVja2VkfWZ1bmN0aW9uIGJsKGEpe3JldHVybiB0eXBlb2YgYS5n
ZXRFbGVtZW50c0J5VGFnTmFtZSE9InVuZGVmaW5lZCI/YS5nZXRFbGVtZW50c0J5VGFnTmFtZSgi
KiIpOnR5cGVvZiBhLnF1ZXJ5U2VsZWN0b3JBbGwhPSJ1bmRlZmluZWQiP2EucXVlcnlTZWxlY3Rv
ckFsbCgiKiIpOltdfWZ1bmN0aW9uIGJrKGEsYil7dmFyIGM7Yi5ub2RlVHlwZT09PTEmJihiLmNs
ZWFyQXR0cmlidXRlcyYmYi5jbGVhckF0dHJpYnV0ZXMoKSxiLm1lcmdlQXR0cmlidXRlcyYmYi5t
ZXJnZUF0dHJpYnV0ZXMoYSksYz1iLm5vZGVOYW1lLnRvTG93ZXJDYXNlKCksYz09PSJvYmplY3Qi
P2Iub3V0ZXJIVE1MPWEub3V0ZXJIVE1MOmMhPT0iaW5wdXQifHxhLnR5cGUhPT0iY2hlY2tib3gi
JiZhLnR5cGUhPT0icmFkaW8iP2M9PT0ib3B0aW9uIj9iLnNlbGVjdGVkPWEuZGVmYXVsdFNlbGVj
dGVkOmM9PT0iaW5wdXQifHxjPT09InRleHRhcmVhIj9iLmRlZmF1bHRWYWx1ZT1hLmRlZmF1bHRW
YWx1ZTpjPT09InNjcmlwdCImJmIudGV4dCE9PWEudGV4dCYmKGIudGV4dD1hLnRleHQpOihhLmNo
ZWNrZWQmJihiLmRlZmF1bHRDaGVja2VkPWIuY2hlY2tlZD1hLmNoZWNrZWQpLGIudmFsdWUhPT1h
LnZhbHVlJiYoYi52YWx1ZT1hLnZhbHVlKSksYi5yZW1vdmVBdHRyaWJ1dGUoZi5leHBhbmRvKSxi
LnJlbW92ZUF0dHJpYnV0ZSgiX3N1Ym1pdF9hdHRhY2hlZCIpLGIucmVtb3ZlQXR0cmlidXRlKCJf
Y2hhbmdlX2F0dGFjaGVkIikpfWZ1bmN0aW9uIGJqKGEsYil7aWYoYi5ub2RlVHlwZT09PTEmJiEh
Zi5oYXNEYXRhKGEpKXt2YXIgYyxkLGUsZz1mLl9kYXRhKGEpLGg9Zi5fZGF0YShiLGcpLGk9Zy5l
dmVudHM7aWYoaSl7ZGVsZXRlIGguaGFuZGxlLGguZXZlbnRzPXt9O2ZvcihjIGluIGkpZm9yKGQ9
MCxlPWlbY10ubGVuZ3RoO2Q8ZTtkKyspZi5ldmVudC5hZGQoYixjLGlbY11bZF0pfWguZGF0YSYm
KGguZGF0YT1mLmV4dGVuZCh7fSxoLmRhdGEpKX19ZnVuY3Rpb24gYmkoYSxiKXtyZXR1cm4gZi5u
b2RlTmFtZShhLCJ0YWJsZSIpP2EuZ2V0RWxlbWVudHNCeVRhZ05hbWUoInRib2R5IilbMF18fGEu
YXBwZW5kQ2hpbGQoYS5vd25lckRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoInRib2R5IikpOmF9ZnVu
Y3Rpb24gVShhKXt2YXIgYj1WLnNwbGl0KCJ8IiksYz1hLmNyZWF0ZURvY3VtZW50RnJhZ21lbnQo
KTtpZihjLmNyZWF0ZUVsZW1lbnQpd2hpbGUoYi5sZW5ndGgpYy5jcmVhdGVFbGVtZW50KGIucG9w
KCkpO3JldHVybiBjfWZ1bmN0aW9uIFQoYSxiLGMpe2I9Ynx8MDtpZihmLmlzRnVuY3Rpb24oYikp
cmV0dXJuIGYuZ3JlcChhLGZ1bmN0aW9uKGEsZCl7dmFyIGU9ISFiLmNhbGwoYSxkLGEpO3JldHVy
biBlPT09Y30pO2lmKGIubm9kZVR5cGUpcmV0dXJuIGYuZ3JlcChhLGZ1bmN0aW9uKGEsZCl7cmV0
dXJuIGE9PT1iPT09Y30pO2lmKHR5cGVvZiBiPT0ic3RyaW5nIil7dmFyIGQ9Zi5ncmVwKGEsZnVu
Y3Rpb24oYSl7cmV0dXJuIGEubm9kZVR5cGU9PT0xfSk7aWYoTy50ZXN0KGIpKXJldHVybiBmLmZp
bHRlcihiLGQsIWMpO2I9Zi5maWx0ZXIoYixkKX1yZXR1cm4gZi5ncmVwKGEsZnVuY3Rpb24oYSxk
KXtyZXR1cm4gZi5pbkFycmF5KGEsYik+PTA9PT1jfSl9ZnVuY3Rpb24gUyhhKXtyZXR1cm4hYXx8
IWEucGFyZW50Tm9kZXx8YS5wYXJlbnROb2RlLm5vZGVUeXBlPT09MTF9ZnVuY3Rpb24gSygpe3Jl
dHVybiEwfWZ1bmN0aW9uIEooKXtyZXR1cm4hMX1mdW5jdGlvbiBuKGEsYixjKXt2YXIgZD1iKyJk
ZWZlciIsZT1iKyJxdWV1ZSIsZz1iKyJtYXJrIixoPWYuX2RhdGEoYSxkKTtoJiYoYz09PSJxdWV1
ZSJ8fCFmLl9kYXRhKGEsZSkpJiYoYz09PSJtYXJrInx8IWYuX2RhdGEoYSxnKSkmJnNldFRpbWVv
dXQoZnVuY3Rpb24oKXshZi5fZGF0YShhLGUpJiYhZi5fZGF0YShhLGcpJiYoZi5yZW1vdmVEYXRh
KGEsZCwhMCksaC5maXJlKCkpfSwwKX1mdW5jdGlvbiBtKGEpe2Zvcih2YXIgYiBpbiBhKXtpZihi
PT09ImRhdGEiJiZmLmlzRW1wdHlPYmplY3QoYVtiXSkpY29udGludWU7aWYoYiE9PSJ0b0pTT04i
KXJldHVybiExfXJldHVybiEwfWZ1bmN0aW9uIGwoYSxjLGQpe2lmKGQ9PT1iJiZhLm5vZGVUeXBl
PT09MSl7dmFyIGU9ImRhdGEtIitjLnJlcGxhY2UoaywiLSQxIikudG9Mb3dlckNhc2UoKTtkPWEu
Z2V0QXR0cmlidXRlKGUpO2lmKHR5cGVvZiBkPT0ic3RyaW5nIil7dHJ5e2Q9ZD09PSJ0cnVlIj8h
MDpkPT09ImZhbHNlIj8hMTpkPT09Im51bGwiP251bGw6Zi5pc051bWVyaWMoZCk/K2Q6ai50ZXN0
KGQpP2YucGFyc2VKU09OKGQpOmR9Y2F0Y2goZyl7fWYuZGF0YShhLGMsZCl9ZWxzZSBkPWJ9cmV0
dXJuIGR9ZnVuY3Rpb24gaChhKXt2YXIgYj1nW2FdPXt9LGMsZDthPWEuc3BsaXQoL1xzKy8pO2Zv
cihjPTAsZD1hLmxlbmd0aDtjPGQ7YysrKWJbYVtjXV09ITA7cmV0dXJuIGJ9dmFyIGM9YS5kb2N1
bWVudCxkPWEubmF2aWdhdG9yLGU9YS5sb2NhdGlvbixmPWZ1bmN0aW9uKCl7ZnVuY3Rpb24gSigp
e2lmKCFlLmlzUmVhZHkpe3RyeXtjLmRvY3VtZW50RWxlbWVudC5kb1Njcm9sbCgibGVmdCIpfWNh
dGNoKGEpe3NldFRpbWVvdXQoSiwxKTtyZXR1cm59ZS5yZWFkeSgpfX12YXIgZT1mdW5jdGlvbihh
LGIpe3JldHVybiBuZXcgZS5mbi5pbml0KGEsYixoKX0sZj1hLmpRdWVyeSxnPWEuJCxoLGk9L14o
PzpbXiM8XSooPFtcd1xXXSs+KVtePl0qJHwjKFtcd1wtXSopJCkvLGo9L1xTLyxrPS9eXHMrLyxs
PS9ccyskLyxtPS9ePChcdyspXHMqXC8/Pig/OjxcL1wxPik/JC8sbj0vXltcXSw6e31cc10qJC8s
bz0vXFwoPzpbIlxcXC9iZm5ydF18dVswLTlhLWZBLUZdezR9KS9nLHA9LyJbXiJcXFxuXHJdKiJ8
dHJ1ZXxmYWxzZXxudWxsfC0/XGQrKD86XC5cZCopPyg/OltlRV1bK1wtXT9cZCspPy9nLHE9Lyg/
Ol58OnwsKSg/OlxzKlxbKSsvZyxyPS8od2Via2l0KVsgXC9dKFtcdy5dKykvLHM9LyhvcGVyYSko
PzouKnZlcnNpb24pP1sgXC9dKFtcdy5dKykvLHQ9Lyhtc2llKSAoW1x3Ll0rKS8sdT0vKG1vemls
bGEpKD86Lio/IHJ2OihbXHcuXSspKT8vLHY9Ly0oW2Etel18WzAtOV0pL2lnLHc9L14tbXMtLyx4
PWZ1bmN0aW9uKGEsYil7cmV0dXJuKGIrIiIpLnRvVXBwZXJDYXNlKCl9LHk9ZC51c2VyQWdlbnQs
eixBLEIsQz1PYmplY3QucHJvdG90eXBlLnRvU3RyaW5nLEQ9T2JqZWN0LnByb3RvdHlwZS5oYXNP
d25Qcm9wZXJ0eSxFPUFycmF5LnByb3RvdHlwZS5wdXNoLEY9QXJyYXkucHJvdG90eXBlLnNsaWNl
LEc9U3RyaW5nLnByb3RvdHlwZS50cmltLEg9QXJyYXkucHJvdG90eXBlLmluZGV4T2YsST17fTtl
LmZuPWUucHJvdG90eXBlPXtjb25zdHJ1Y3RvcjplLGluaXQ6ZnVuY3Rpb24oYSxkLGYpe3ZhciBn
LGgsaixrO2lmKCFhKXJldHVybiB0aGlzO2lmKGEubm9kZVR5cGUpe3RoaXMuY29udGV4dD10aGlz
WzBdPWEsdGhpcy5sZW5ndGg9MTtyZXR1cm4gdGhpc31pZihhPT09ImJvZHkiJiYhZCYmYy5ib2R5
KXt0aGlzLmNvbnRleHQ9Yyx0aGlzWzBdPWMuYm9keSx0aGlzLnNlbGVjdG9yPWEsdGhpcy5sZW5n
dGg9MTtyZXR1cm4gdGhpc31pZih0eXBlb2YgYT09InN0cmluZyIpe2EuY2hhckF0KDApIT09Ijwi
fHxhLmNoYXJBdChhLmxlbmd0aC0xKSE9PSI+Inx8YS5sZW5ndGg8Mz9nPWkuZXhlYyhhKTpnPVtu
dWxsLGEsbnVsbF07aWYoZyYmKGdbMV18fCFkKSl7aWYoZ1sxXSl7ZD1kIGluc3RhbmNlb2YgZT9k
WzBdOmQsaz1kP2Qub3duZXJEb2N1bWVudHx8ZDpjLGo9bS5leGVjKGEpLGo/ZS5pc1BsYWluT2Jq
ZWN0KGQpPyhhPVtjLmNyZWF0ZUVsZW1lbnQoalsxXSldLGUuZm4uYXR0ci5jYWxsKGEsZCwhMCkp
OmE9W2suY3JlYXRlRWxlbWVudChqWzFdKV06KGo9ZS5idWlsZEZyYWdtZW50KFtnWzFdXSxba10p
LGE9KGouY2FjaGVhYmxlP2UuY2xvbmUoai5mcmFnbWVudCk6ai5mcmFnbWVudCkuY2hpbGROb2Rl
cyk7cmV0dXJuIGUubWVyZ2UodGhpcyxhKX1oPWMuZ2V0RWxlbWVudEJ5SWQoZ1syXSk7aWYoaCYm
aC5wYXJlbnROb2RlKXtpZihoLmlkIT09Z1syXSlyZXR1cm4gZi5maW5kKGEpO3RoaXMubGVuZ3Ro
PTEsdGhpc1swXT1ofXRoaXMuY29udGV4dD1jLHRoaXMuc2VsZWN0b3I9YTtyZXR1cm4gdGhpc31y
ZXR1cm4hZHx8ZC5qcXVlcnk/KGR8fGYpLmZpbmQoYSk6dGhpcy5jb25zdHJ1Y3RvcihkKS5maW5k
KGEpfWlmKGUuaXNGdW5jdGlvbihhKSlyZXR1cm4gZi5yZWFkeShhKTthLnNlbGVjdG9yIT09YiYm
KHRoaXMuc2VsZWN0b3I9YS5zZWxlY3Rvcix0aGlzLmNvbnRleHQ9YS5jb250ZXh0KTtyZXR1cm4g
ZS5tYWtlQXJyYXkoYSx0aGlzKX0sc2VsZWN0b3I6IiIsanF1ZXJ5OiIxLjcuMiIsbGVuZ3RoOjAs
c2l6ZTpmdW5jdGlvbigpe3JldHVybiB0aGlzLmxlbmd0aH0sdG9BcnJheTpmdW5jdGlvbigpe3Jl
dHVybiBGLmNhbGwodGhpcywwKX0sZ2V0OmZ1bmN0aW9uKGEpe3JldHVybiBhPT1udWxsP3RoaXMu
dG9BcnJheSgpOmE8MD90aGlzW3RoaXMubGVuZ3RoK2FdOnRoaXNbYV19LHB1c2hTdGFjazpmdW5j
dGlvbihhLGIsYyl7dmFyIGQ9dGhpcy5jb25zdHJ1Y3RvcigpO2UuaXNBcnJheShhKT9FLmFwcGx5
KGQsYSk6ZS5tZXJnZShkLGEpLGQucHJldk9iamVjdD10aGlzLGQuY29udGV4dD10aGlzLmNvbnRl
eHQsYj09PSJmaW5kIj9kLnNlbGVjdG9yPXRoaXMuc2VsZWN0b3IrKHRoaXMuc2VsZWN0b3I/IiAi
OiIiKStjOmImJihkLnNlbGVjdG9yPXRoaXMuc2VsZWN0b3IrIi4iK2IrIigiK2MrIikiKTtyZXR1
cm4gZH0sZWFjaDpmdW5jdGlvbihhLGIpe3JldHVybiBlLmVhY2godGhpcyxhLGIpfSxyZWFkeTpm
dW5jdGlvbihhKXtlLmJpbmRSZWFkeSgpLEEuYWRkKGEpO3JldHVybiB0aGlzfSxlcTpmdW5jdGlv
bihhKXthPSthO3JldHVybiBhPT09LTE/dGhpcy5zbGljZShhKTp0aGlzLnNsaWNlKGEsYSsxKX0s
Zmlyc3Q6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5lcSgwKX0sbGFzdDpmdW5jdGlvbigpe3JldHVy
biB0aGlzLmVxKC0xKX0sc2xpY2U6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5wdXNoU3RhY2soRi5h
cHBseSh0aGlzLGFyZ3VtZW50cyksInNsaWNlIixGLmNhbGwoYXJndW1lbnRzKS5qb2luKCIsIikp
fSxtYXA6ZnVuY3Rpb24oYSl7cmV0dXJuIHRoaXMucHVzaFN0YWNrKGUubWFwKHRoaXMsZnVuY3Rp
b24oYixjKXtyZXR1cm4gYS5jYWxsKGIsYyxiKX0pKX0sZW5kOmZ1bmN0aW9uKCl7cmV0dXJuIHRo
aXMucHJldk9iamVjdHx8dGhpcy5jb25zdHJ1Y3RvcihudWxsKX0scHVzaDpFLHNvcnQ6W10uc29y
dCxzcGxpY2U6W10uc3BsaWNlfSxlLmZuLmluaXQucHJvdG90eXBlPWUuZm4sZS5leHRlbmQ9ZS5m
bi5leHRlbmQ9ZnVuY3Rpb24oKXt2YXIgYSxjLGQsZixnLGgsaT1hcmd1bWVudHNbMF18fHt9LGo9
MSxrPWFyZ3VtZW50cy5sZW5ndGgsbD0hMTt0eXBlb2YgaT09ImJvb2xlYW4iJiYobD1pLGk9YXJn
dW1lbnRzWzFdfHx7fSxqPTIpLHR5cGVvZiBpIT0ib2JqZWN0IiYmIWUuaXNGdW5jdGlvbihpKSYm
KGk9e30pLGs9PT1qJiYoaT10aGlzLC0taik7Zm9yKDtqPGs7aisrKWlmKChhPWFyZ3VtZW50c1tq
XSkhPW51bGwpZm9yKGMgaW4gYSl7ZD1pW2NdLGY9YVtjXTtpZihpPT09Ziljb250aW51ZTtsJiZm
JiYoZS5pc1BsYWluT2JqZWN0KGYpfHwoZz1lLmlzQXJyYXkoZikpKT8oZz8oZz0hMSxoPWQmJmUu
aXNBcnJheShkKT9kOltdKTpoPWQmJmUuaXNQbGFpbk9iamVjdChkKT9kOnt9LGlbY109ZS5leHRl
bmQobCxoLGYpKTpmIT09YiYmKGlbY109Zil9cmV0dXJuIGl9LGUuZXh0ZW5kKHtub0NvbmZsaWN0
OmZ1bmN0aW9uKGIpe2EuJD09PWUmJihhLiQ9ZyksYiYmYS5qUXVlcnk9PT1lJiYoYS5qUXVlcnk9
Zik7cmV0dXJuIGV9LGlzUmVhZHk6ITEscmVhZHlXYWl0OjEsaG9sZFJlYWR5OmZ1bmN0aW9uKGEp
e2E/ZS5yZWFkeVdhaXQrKzplLnJlYWR5KCEwKX0scmVhZHk6ZnVuY3Rpb24oYSl7aWYoYT09PSEw
JiYhLS1lLnJlYWR5V2FpdHx8YSE9PSEwJiYhZS5pc1JlYWR5KXtpZighYy5ib2R5KXJldHVybiBz
ZXRUaW1lb3V0KGUucmVhZHksMSk7ZS5pc1JlYWR5PSEwO2lmKGEhPT0hMCYmLS1lLnJlYWR5V2Fp
dD4wKXJldHVybjtBLmZpcmVXaXRoKGMsW2VdKSxlLmZuLnRyaWdnZXImJmUoYykudHJpZ2dlcigi
cmVhZHkiKS5vZmYoInJlYWR5Iil9fSxiaW5kUmVhZHk6ZnVuY3Rpb24oKXtpZighQSl7QT1lLkNh
bGxiYWNrcygib25jZSBtZW1vcnkiKTtpZihjLnJlYWR5U3RhdGU9PT0iY29tcGxldGUiKXJldHVy
biBzZXRUaW1lb3V0KGUucmVhZHksMSk7aWYoYy5hZGRFdmVudExpc3RlbmVyKWMuYWRkRXZlbnRM
aXN0ZW5lcigiRE9NQ29udGVudExvYWRlZCIsQiwhMSksYS5hZGRFdmVudExpc3RlbmVyKCJsb2Fk
IixlLnJlYWR5LCExKTtlbHNlIGlmKGMuYXR0YWNoRXZlbnQpe2MuYXR0YWNoRXZlbnQoIm9ucmVh
ZHlzdGF0ZWNoYW5nZSIsQiksYS5hdHRhY2hFdmVudCgib25sb2FkIixlLnJlYWR5KTt2YXIgYj0h
MTt0cnl7Yj1hLmZyYW1lRWxlbWVudD09bnVsbH1jYXRjaChkKXt9Yy5kb2N1bWVudEVsZW1lbnQu
ZG9TY3JvbGwmJmImJkooKX19fSxpc0Z1bmN0aW9uOmZ1bmN0aW9uKGEpe3JldHVybiBlLnR5cGUo
YSk9PT0iZnVuY3Rpb24ifSxpc0FycmF5OkFycmF5LmlzQXJyYXl8fGZ1bmN0aW9uKGEpe3JldHVy
biBlLnR5cGUoYSk9PT0iYXJyYXkifSxpc1dpbmRvdzpmdW5jdGlvbihhKXtyZXR1cm4gYSE9bnVs
bCYmYT09YS53aW5kb3d9LGlzTnVtZXJpYzpmdW5jdGlvbihhKXtyZXR1cm4haXNOYU4ocGFyc2VG
bG9hdChhKSkmJmlzRmluaXRlKGEpfSx0eXBlOmZ1bmN0aW9uKGEpe3JldHVybiBhPT1udWxsP1N0
cmluZyhhKTpJW0MuY2FsbChhKV18fCJvYmplY3QifSxpc1BsYWluT2JqZWN0OmZ1bmN0aW9uKGEp
e2lmKCFhfHxlLnR5cGUoYSkhPT0ib2JqZWN0Inx8YS5ub2RlVHlwZXx8ZS5pc1dpbmRvdyhhKSly
ZXR1cm4hMTt0cnl7aWYoYS5jb25zdHJ1Y3RvciYmIUQuY2FsbChhLCJjb25zdHJ1Y3RvciIpJiYh
RC5jYWxsKGEuY29uc3RydWN0b3IucHJvdG90eXBlLCJpc1Byb3RvdHlwZU9mIikpcmV0dXJuITF9
Y2F0Y2goYyl7cmV0dXJuITF9dmFyIGQ7Zm9yKGQgaW4gYSk7cmV0dXJuIGQ9PT1ifHxELmNhbGwo
YSxkKX0saXNFbXB0eU9iamVjdDpmdW5jdGlvbihhKXtmb3IodmFyIGIgaW4gYSlyZXR1cm4hMTty
ZXR1cm4hMH0sZXJyb3I6ZnVuY3Rpb24oYSl7dGhyb3cgbmV3IEVycm9yKGEpfSxwYXJzZUpTT046
ZnVuY3Rpb24oYil7aWYodHlwZW9mIGIhPSJzdHJpbmcifHwhYilyZXR1cm4gbnVsbDtiPWUudHJp
bShiKTtpZihhLkpTT04mJmEuSlNPTi5wYXJzZSlyZXR1cm4gYS5KU09OLnBhcnNlKGIpO2lmKG4u
dGVzdChiLnJlcGxhY2UobywiQCIpLnJlcGxhY2UocCwiXSIpLnJlcGxhY2UocSwiIikpKXJldHVy
bihuZXcgRnVuY3Rpb24oInJldHVybiAiK2IpKSgpO2UuZXJyb3IoIkludmFsaWQgSlNPTjogIiti
KX0scGFyc2VYTUw6ZnVuY3Rpb24oYyl7aWYodHlwZW9mIGMhPSJzdHJpbmcifHwhYylyZXR1cm4g
bnVsbDt2YXIgZCxmO3RyeXthLkRPTVBhcnNlcj8oZj1uZXcgRE9NUGFyc2VyLGQ9Zi5wYXJzZUZy
b21TdHJpbmcoYywidGV4dC94bWwiKSk6KGQ9bmV3IEFjdGl2ZVhPYmplY3QoIk1pY3Jvc29mdC5Y
TUxET00iKSxkLmFzeW5jPSJmYWxzZSIsZC5sb2FkWE1MKGMpKX1jYXRjaChnKXtkPWJ9KCFkfHwh
ZC5kb2N1bWVudEVsZW1lbnR8fGQuZ2V0RWxlbWVudHNCeVRhZ05hbWUoInBhcnNlcmVycm9yIiku
bGVuZ3RoKSYmZS5lcnJvcigiSW52YWxpZCBYTUw6ICIrYyk7cmV0dXJuIGR9LG5vb3A6ZnVuY3Rp
b24oKXt9LGdsb2JhbEV2YWw6ZnVuY3Rpb24oYil7YiYmai50ZXN0KGIpJiYoYS5leGVjU2NyaXB0
fHxmdW5jdGlvbihiKXthLmV2YWwuY2FsbChhLGIpfSkoYil9LGNhbWVsQ2FzZTpmdW5jdGlvbihh
KXtyZXR1cm4gYS5yZXBsYWNlKHcsIm1zLSIpLnJlcGxhY2Uodix4KX0sbm9kZU5hbWU6ZnVuY3Rp
b24oYSxiKXtyZXR1cm4gYS5ub2RlTmFtZSYmYS5ub2RlTmFtZS50b1VwcGVyQ2FzZSgpPT09Yi50
b1VwcGVyQ2FzZSgpfSxlYWNoOmZ1bmN0aW9uKGEsYyxkKXt2YXIgZixnPTAsaD1hLmxlbmd0aCxp
PWg9PT1ifHxlLmlzRnVuY3Rpb24oYSk7aWYoZCl7aWYoaSl7Zm9yKGYgaW4gYSlpZihjLmFwcGx5
KGFbZl0sZCk9PT0hMSlicmVha31lbHNlIGZvcig7ZzxoOylpZihjLmFwcGx5KGFbZysrXSxkKT09
PSExKWJyZWFrfWVsc2UgaWYoaSl7Zm9yKGYgaW4gYSlpZihjLmNhbGwoYVtmXSxmLGFbZl0pPT09
ITEpYnJlYWt9ZWxzZSBmb3IoO2c8aDspaWYoYy5jYWxsKGFbZ10sZyxhW2crK10pPT09ITEpYnJl
YWs7cmV0dXJuIGF9LHRyaW06Rz9mdW5jdGlvbihhKXtyZXR1cm4gYT09bnVsbD8iIjpHLmNhbGwo
YSl9OmZ1bmN0aW9uKGEpe3JldHVybiBhPT1udWxsPyIiOihhKyIiKS5yZXBsYWNlKGssIiIpLnJl
cGxhY2UobCwiIil9LG1ha2VBcnJheTpmdW5jdGlvbihhLGIpe3ZhciBjPWJ8fFtdO2lmKGEhPW51
bGwpe3ZhciBkPWUudHlwZShhKTthLmxlbmd0aD09bnVsbHx8ZD09PSJzdHJpbmcifHxkPT09ImZ1
bmN0aW9uInx8ZD09PSJyZWdleHAifHxlLmlzV2luZG93KGEpP0UuY2FsbChjLGEpOmUubWVyZ2Uo
YyxhKX1yZXR1cm4gY30saW5BcnJheTpmdW5jdGlvbihhLGIsYyl7dmFyIGQ7aWYoYil7aWYoSCly
ZXR1cm4gSC5jYWxsKGIsYSxjKTtkPWIubGVuZ3RoLGM9Yz9jPDA/TWF0aC5tYXgoMCxkK2MpOmM6
MDtmb3IoO2M8ZDtjKyspaWYoYyBpbiBiJiZiW2NdPT09YSlyZXR1cm4gY31yZXR1cm4tMX0sbWVy
Z2U6ZnVuY3Rpb24oYSxjKXt2YXIgZD1hLmxlbmd0aCxlPTA7aWYodHlwZW9mIGMubGVuZ3RoPT0i
bnVtYmVyIilmb3IodmFyIGY9Yy5sZW5ndGg7ZTxmO2UrKylhW2QrK109Y1tlXTtlbHNlIHdoaWxl
KGNbZV0hPT1iKWFbZCsrXT1jW2UrK107YS5sZW5ndGg9ZDtyZXR1cm4gYX0sZ3JlcDpmdW5jdGlv
bihhLGIsYyl7dmFyIGQ9W10sZTtjPSEhYztmb3IodmFyIGY9MCxnPWEubGVuZ3RoO2Y8ZztmKysp
ZT0hIWIoYVtmXSxmKSxjIT09ZSYmZC5wdXNoKGFbZl0pO3JldHVybiBkfSxtYXA6ZnVuY3Rpb24o
YSxjLGQpe3ZhciBmLGcsaD1bXSxpPTAsaj1hLmxlbmd0aCxrPWEgaW5zdGFuY2VvZiBlfHxqIT09
YiYmdHlwZW9mIGo9PSJudW1iZXIiJiYoaj4wJiZhWzBdJiZhW2otMV18fGo9PT0wfHxlLmlzQXJy
YXkoYSkpO2lmKGspZm9yKDtpPGo7aSsrKWY9YyhhW2ldLGksZCksZiE9bnVsbCYmKGhbaC5sZW5n
dGhdPWYpO2Vsc2UgZm9yKGcgaW4gYSlmPWMoYVtnXSxnLGQpLGYhPW51bGwmJihoW2gubGVuZ3Ro
XT1mKTtyZXR1cm4gaC5jb25jYXQuYXBwbHkoW10saCl9LGd1aWQ6MSxwcm94eTpmdW5jdGlvbihh
LGMpe2lmKHR5cGVvZiBjPT0ic3RyaW5nIil7dmFyIGQ9YVtjXTtjPWEsYT1kfWlmKCFlLmlzRnVu
Y3Rpb24oYSkpcmV0dXJuIGI7dmFyIGY9Ri5jYWxsKGFyZ3VtZW50cywyKSxnPWZ1bmN0aW9uKCl7
cmV0dXJuIGEuYXBwbHkoYyxmLmNvbmNhdChGLmNhbGwoYXJndW1lbnRzKSkpfTtnLmd1aWQ9YS5n
dWlkPWEuZ3VpZHx8Zy5ndWlkfHxlLmd1aWQrKztyZXR1cm4gZ30sYWNjZXNzOmZ1bmN0aW9uKGEs
YyxkLGYsZyxoLGkpe3ZhciBqLGs9ZD09bnVsbCxsPTAsbT1hLmxlbmd0aDtpZihkJiZ0eXBlb2Yg
ZD09Im9iamVjdCIpe2ZvcihsIGluIGQpZS5hY2Nlc3MoYSxjLGwsZFtsXSwxLGgsZik7Zz0xfWVs
c2UgaWYoZiE9PWIpe2o9aT09PWImJmUuaXNGdW5jdGlvbihmKSxrJiYoaj8oaj1jLGM9ZnVuY3Rp
b24oYSxiLGMpe3JldHVybiBqLmNhbGwoZShhKSxjKX0pOihjLmNhbGwoYSxmKSxjPW51bGwpKTtp
ZihjKWZvcig7bDxtO2wrKyljKGFbbF0sZCxqP2YuY2FsbChhW2xdLGwsYyhhW2xdLGQpKTpmLGkp
O2c9MX1yZXR1cm4gZz9hOms/Yy5jYWxsKGEpOm0/YyhhWzBdLGQpOmh9LG5vdzpmdW5jdGlvbigp
e3JldHVybihuZXcgRGF0ZSkuZ2V0VGltZSgpfSx1YU1hdGNoOmZ1bmN0aW9uKGEpe2E9YS50b0xv
d2VyQ2FzZSgpO3ZhciBiPXIuZXhlYyhhKXx8cy5leGVjKGEpfHx0LmV4ZWMoYSl8fGEuaW5kZXhP
ZigiY29tcGF0aWJsZSIpPDAmJnUuZXhlYyhhKXx8W107cmV0dXJue2Jyb3dzZXI6YlsxXXx8IiIs
dmVyc2lvbjpiWzJdfHwiMCJ9fSxzdWI6ZnVuY3Rpb24oKXtmdW5jdGlvbiBhKGIsYyl7cmV0dXJu
IG5ldyBhLmZuLmluaXQoYixjKX1lLmV4dGVuZCghMCxhLHRoaXMpLGEuc3VwZXJjbGFzcz10aGlz
LGEuZm49YS5wcm90b3R5cGU9dGhpcygpLGEuZm4uY29uc3RydWN0b3I9YSxhLnN1Yj10aGlzLnN1
YixhLmZuLmluaXQ9ZnVuY3Rpb24oZCxmKXtmJiZmIGluc3RhbmNlb2YgZSYmIShmIGluc3RhbmNl
b2YgYSkmJihmPWEoZikpO3JldHVybiBlLmZuLmluaXQuY2FsbCh0aGlzLGQsZixiKX0sYS5mbi5p
bml0LnByb3RvdHlwZT1hLmZuO3ZhciBiPWEoYyk7cmV0dXJuIGF9LGJyb3dzZXI6e319KSxlLmVh
Y2goIkJvb2xlYW4gTnVtYmVyIFN0cmluZyBGdW5jdGlvbiBBcnJheSBEYXRlIFJlZ0V4cCBPYmpl
Y3QiLnNwbGl0KCIgIiksZnVuY3Rpb24oYSxiKXtJWyJbb2JqZWN0ICIrYisiXSJdPWIudG9Mb3dl
ckNhc2UoKX0pLHo9ZS51YU1hdGNoKHkpLHouYnJvd3NlciYmKGUuYnJvd3Nlclt6LmJyb3dzZXJd
PSEwLGUuYnJvd3Nlci52ZXJzaW9uPXoudmVyc2lvbiksZS5icm93c2VyLndlYmtpdCYmKGUuYnJv
d3Nlci5zYWZhcmk9ITApLGoudGVzdCgiwqAiKSYmKGs9L15bXHNceEEwXSsvLGw9L1tcc1x4QTBd
KyQvKSxoPWUoYyksYy5hZGRFdmVudExpc3RlbmVyP0I9ZnVuY3Rpb24oKXtjLnJlbW92ZUV2ZW50
TGlzdGVuZXIoIkRPTUNvbnRlbnRMb2FkZWQiLEIsITEpLGUucmVhZHkoKX06Yy5hdHRhY2hFdmVu
dCYmKEI9ZnVuY3Rpb24oKXtjLnJlYWR5U3RhdGU9PT0iY29tcGxldGUiJiYoYy5kZXRhY2hFdmVu
dCgib25yZWFkeXN0YXRlY2hhbmdlIixCKSxlLnJlYWR5KCkpfSk7cmV0dXJuIGV9KCksZz17fTtm
LkNhbGxiYWNrcz1mdW5jdGlvbihhKXthPWE/Z1thXXx8aChhKTp7fTt2YXIgYz1bXSxkPVtdLGUs
aSxqLGssbCxtLG49ZnVuY3Rpb24oYil7dmFyIGQsZSxnLGgsaTtmb3IoZD0wLGU9Yi5sZW5ndGg7
ZDxlO2QrKylnPWJbZF0saD1mLnR5cGUoZyksaD09PSJhcnJheSI/bihnKTpoPT09ImZ1bmN0aW9u
IiYmKCFhLnVuaXF1ZXx8IXAuaGFzKGcpKSYmYy5wdXNoKGcpfSxvPWZ1bmN0aW9uKGIsZil7Zj1m
fHxbXSxlPSFhLm1lbW9yeXx8W2IsZl0saT0hMCxqPSEwLG09a3x8MCxrPTAsbD1jLmxlbmd0aDtm
b3IoO2MmJm08bDttKyspaWYoY1ttXS5hcHBseShiLGYpPT09ITEmJmEuc3RvcE9uRmFsc2Upe2U9
ITA7YnJlYWt9aj0hMSxjJiYoYS5vbmNlP2U9PT0hMD9wLmRpc2FibGUoKTpjPVtdOmQmJmQubGVu
Z3RoJiYoZT1kLnNoaWZ0KCkscC5maXJlV2l0aChlWzBdLGVbMV0pKSl9LHA9e2FkZDpmdW5jdGlv
bigpe2lmKGMpe3ZhciBhPWMubGVuZ3RoO24oYXJndW1lbnRzKSxqP2w9Yy5sZW5ndGg6ZSYmZSE9
PSEwJiYoaz1hLG8oZVswXSxlWzFdKSl9cmV0dXJuIHRoaXN9LHJlbW92ZTpmdW5jdGlvbigpe2lm
KGMpe3ZhciBiPWFyZ3VtZW50cyxkPTAsZT1iLmxlbmd0aDtmb3IoO2Q8ZTtkKyspZm9yKHZhciBm
PTA7ZjxjLmxlbmd0aDtmKyspaWYoYltkXT09PWNbZl0pe2omJmY8PWwmJihsLS0sZjw9bSYmbS0t
KSxjLnNwbGljZShmLS0sMSk7aWYoYS51bmlxdWUpYnJlYWt9fXJldHVybiB0aGlzfSxoYXM6ZnVu
Y3Rpb24oYSl7aWYoYyl7dmFyIGI9MCxkPWMubGVuZ3RoO2Zvcig7YjxkO2IrKylpZihhPT09Y1ti
XSlyZXR1cm4hMH1yZXR1cm4hMX0sZW1wdHk6ZnVuY3Rpb24oKXtjPVtdO3JldHVybiB0aGlzfSxk
aXNhYmxlOmZ1bmN0aW9uKCl7Yz1kPWU9YjtyZXR1cm4gdGhpc30sZGlzYWJsZWQ6ZnVuY3Rpb24o
KXtyZXR1cm4hY30sbG9jazpmdW5jdGlvbigpe2Q9YiwoIWV8fGU9PT0hMCkmJnAuZGlzYWJsZSgp
O3JldHVybiB0aGlzfSxsb2NrZWQ6ZnVuY3Rpb24oKXtyZXR1cm4hZH0sZmlyZVdpdGg6ZnVuY3Rp
b24oYixjKXtkJiYoaj9hLm9uY2V8fGQucHVzaChbYixjXSk6KCFhLm9uY2V8fCFlKSYmbyhiLGMp
KTtyZXR1cm4gdGhpc30sZmlyZTpmdW5jdGlvbigpe3AuZmlyZVdpdGgodGhpcyxhcmd1bWVudHMp
O3JldHVybiB0aGlzfSxmaXJlZDpmdW5jdGlvbigpe3JldHVybiEhaX19O3JldHVybiBwfTt2YXIg
aT1bXS5zbGljZTtmLmV4dGVuZCh7RGVmZXJyZWQ6ZnVuY3Rpb24oYSl7dmFyIGI9Zi5DYWxsYmFj
a3MoIm9uY2UgbWVtb3J5IiksYz1mLkNhbGxiYWNrcygib25jZSBtZW1vcnkiKSxkPWYuQ2FsbGJh
Y2tzKCJtZW1vcnkiKSxlPSJwZW5kaW5nIixnPXtyZXNvbHZlOmIscmVqZWN0OmMsbm90aWZ5OmR9
LGg9e2RvbmU6Yi5hZGQsZmFpbDpjLmFkZCxwcm9ncmVzczpkLmFkZCxzdGF0ZTpmdW5jdGlvbigp
e3JldHVybiBlfSxpc1Jlc29sdmVkOmIuZmlyZWQsaXNSZWplY3RlZDpjLmZpcmVkLHRoZW46ZnVu
Y3Rpb24oYSxiLGMpe2kuZG9uZShhKS5mYWlsKGIpLnByb2dyZXNzKGMpO3JldHVybiB0aGlzfSxh
bHdheXM6ZnVuY3Rpb24oKXtpLmRvbmUuYXBwbHkoaSxhcmd1bWVudHMpLmZhaWwuYXBwbHkoaSxh
cmd1bWVudHMpO3JldHVybiB0aGlzfSxwaXBlOmZ1bmN0aW9uKGEsYixjKXtyZXR1cm4gZi5EZWZl
cnJlZChmdW5jdGlvbihkKXtmLmVhY2goe2RvbmU6W2EsInJlc29sdmUiXSxmYWlsOltiLCJyZWpl
Y3QiXSxwcm9ncmVzczpbYywibm90aWZ5Il19LGZ1bmN0aW9uKGEsYil7dmFyIGM9YlswXSxlPWJb
MV0sZztmLmlzRnVuY3Rpb24oYyk/aVthXShmdW5jdGlvbigpe2c9Yy5hcHBseSh0aGlzLGFyZ3Vt
ZW50cyksZyYmZi5pc0Z1bmN0aW9uKGcucHJvbWlzZSk/Zy5wcm9taXNlKCkudGhlbihkLnJlc29s
dmUsZC5yZWplY3QsZC5ub3RpZnkpOmRbZSsiV2l0aCJdKHRoaXM9PT1pP2Q6dGhpcyxbZ10pfSk6
aVthXShkW2VdKX0pfSkucHJvbWlzZSgpfSxwcm9taXNlOmZ1bmN0aW9uKGEpe2lmKGE9PW51bGwp
YT1oO2Vsc2UgZm9yKHZhciBiIGluIGgpYVtiXT1oW2JdO3JldHVybiBhfX0saT1oLnByb21pc2Uo
e30pLGo7Zm9yKGogaW4gZylpW2pdPWdbal0uZmlyZSxpW2orIldpdGgiXT1nW2pdLmZpcmVXaXRo
O2kuZG9uZShmdW5jdGlvbigpe2U9InJlc29sdmVkIn0sYy5kaXNhYmxlLGQubG9jaykuZmFpbChm
dW5jdGlvbigpe2U9InJlamVjdGVkIn0sYi5kaXNhYmxlLGQubG9jayksYSYmYS5jYWxsKGksaSk7
cmV0dXJuIGl9LHdoZW46ZnVuY3Rpb24oYSl7ZnVuY3Rpb24gbShhKXtyZXR1cm4gZnVuY3Rpb24o
Yil7ZVthXT1hcmd1bWVudHMubGVuZ3RoPjE/aS5jYWxsKGFyZ3VtZW50cywwKTpiLGoubm90aWZ5
V2l0aChrLGUpfX1mdW5jdGlvbiBsKGEpe3JldHVybiBmdW5jdGlvbihjKXtiW2FdPWFyZ3VtZW50
cy5sZW5ndGg+MT9pLmNhbGwoYXJndW1lbnRzLDApOmMsLS1nfHxqLnJlc29sdmVXaXRoKGosYil9
fXZhciBiPWkuY2FsbChhcmd1bWVudHMsMCksYz0wLGQ9Yi5sZW5ndGgsZT1BcnJheShkKSxnPWQs
aD1kLGo9ZDw9MSYmYSYmZi5pc0Z1bmN0aW9uKGEucHJvbWlzZSk/YTpmLkRlZmVycmVkKCksaz1q
LnByb21pc2UoKTtpZihkPjEpe2Zvcig7YzxkO2MrKyliW2NdJiZiW2NdLnByb21pc2UmJmYuaXNG
dW5jdGlvbihiW2NdLnByb21pc2UpP2JbY10ucHJvbWlzZSgpLnRoZW4obChjKSxqLnJlamVjdCxt
KGMpKTotLWc7Z3x8ai5yZXNvbHZlV2l0aChqLGIpfWVsc2UgaiE9PWEmJmoucmVzb2x2ZVdpdGgo
aixkP1thXTpbXSk7cmV0dXJuIGt9fSksZi5zdXBwb3J0PWZ1bmN0aW9uKCl7dmFyIGIsZCxlLGcs
aCxpLGosayxsLG0sbixvLHA9Yy5jcmVhdGVFbGVtZW50KCJkaXYiKSxxPWMuZG9jdW1lbnRFbGVt
ZW50O3Auc2V0QXR0cmlidXRlKCJjbGFzc05hbWUiLCJ0IikscC5pbm5lckhUTUw9IiAgIDxsaW5r
Lz48dGFibGU+PC90YWJsZT48YSBocmVmPScvYScgc3R5bGU9J3RvcDoxcHg7ZmxvYXQ6bGVmdDtv
cGFjaXR5Oi41NTsnPmE8L2E+PGlucHV0IHR5cGU9J2NoZWNrYm94Jy8+IixkPXAuZ2V0RWxlbWVu
dHNCeVRhZ05hbWUoIioiKSxlPXAuZ2V0RWxlbWVudHNCeVRhZ05hbWUoImEiKVswXTtpZighZHx8
IWQubGVuZ3RofHwhZSlyZXR1cm57fTtnPWMuY3JlYXRlRWxlbWVudCgic2VsZWN0IiksaD1nLmFw
cGVuZENoaWxkKGMuY3JlYXRlRWxlbWVudCgib3B0aW9uIikpLGk9cC5nZXRFbGVtZW50c0J5VGFn
TmFtZSgiaW5wdXQiKVswXSxiPXtsZWFkaW5nV2hpdGVzcGFjZTpwLmZpcnN0Q2hpbGQubm9kZVR5
cGU9PT0zLHRib2R5OiFwLmdldEVsZW1lbnRzQnlUYWdOYW1lKCJ0Ym9keSIpLmxlbmd0aCxodG1s
U2VyaWFsaXplOiEhcC5nZXRFbGVtZW50c0J5VGFnTmFtZSgibGluayIpLmxlbmd0aCxzdHlsZTov
dG9wLy50ZXN0KGUuZ2V0QXR0cmlidXRlKCJzdHlsZSIpKSxocmVmTm9ybWFsaXplZDplLmdldEF0
dHJpYnV0ZSgiaHJlZiIpPT09Ii9hIixvcGFjaXR5Oi9eMC41NS8udGVzdChlLnN0eWxlLm9wYWNp
dHkpLGNzc0Zsb2F0OiEhZS5zdHlsZS5jc3NGbG9hdCxjaGVja09uOmkudmFsdWU9PT0ib24iLG9w
dFNlbGVjdGVkOmguc2VsZWN0ZWQsZ2V0U2V0QXR0cmlidXRlOnAuY2xhc3NOYW1lIT09InQiLGVu
Y3R5cGU6ISFjLmNyZWF0ZUVsZW1lbnQoImZvcm0iKS5lbmN0eXBlLGh0bWw1Q2xvbmU6Yy5jcmVh
dGVFbGVtZW50KCJuYXYiKS5jbG9uZU5vZGUoITApLm91dGVySFRNTCE9PSI8Om5hdj48LzpuYXY+
IixzdWJtaXRCdWJibGVzOiEwLGNoYW5nZUJ1YmJsZXM6ITAsZm9jdXNpbkJ1YmJsZXM6ITEsZGVs
ZXRlRXhwYW5kbzohMCxub0Nsb25lRXZlbnQ6ITAsaW5saW5lQmxvY2tOZWVkc0xheW91dDohMSxz
aHJpbmtXcmFwQmxvY2tzOiExLHJlbGlhYmxlTWFyZ2luUmlnaHQ6ITAscGl4ZWxNYXJnaW46ITB9
LGYuYm94TW9kZWw9Yi5ib3hNb2RlbD1jLmNvbXBhdE1vZGU9PT0iQ1NTMUNvbXBhdCIsaS5jaGVj
a2VkPSEwLGIubm9DbG9uZUNoZWNrZWQ9aS5jbG9uZU5vZGUoITApLmNoZWNrZWQsZy5kaXNhYmxl
ZD0hMCxiLm9wdERpc2FibGVkPSFoLmRpc2FibGVkO3RyeXtkZWxldGUgcC50ZXN0fWNhdGNoKHIp
e2IuZGVsZXRlRXhwYW5kbz0hMX0hcC5hZGRFdmVudExpc3RlbmVyJiZwLmF0dGFjaEV2ZW50JiZw
LmZpcmVFdmVudCYmKHAuYXR0YWNoRXZlbnQoIm9uY2xpY2siLGZ1bmN0aW9uKCl7Yi5ub0Nsb25l
RXZlbnQ9ITF9KSxwLmNsb25lTm9kZSghMCkuZmlyZUV2ZW50KCJvbmNsaWNrIikpLGk9Yy5jcmVh
dGVFbGVtZW50KCJpbnB1dCIpLGkudmFsdWU9InQiLGkuc2V0QXR0cmlidXRlKCJ0eXBlIiwicmFk
aW8iKSxiLnJhZGlvVmFsdWU9aS52YWx1ZT09PSJ0IixpLnNldEF0dHJpYnV0ZSgiY2hlY2tlZCIs
ImNoZWNrZWQiKSxpLnNldEF0dHJpYnV0ZSgibmFtZSIsInQiKSxwLmFwcGVuZENoaWxkKGkpLGo9
Yy5jcmVhdGVEb2N1bWVudEZyYWdtZW50KCksai5hcHBlbmRDaGlsZChwLmxhc3RDaGlsZCksYi5j
aGVja0Nsb25lPWouY2xvbmVOb2RlKCEwKS5jbG9uZU5vZGUoITApLmxhc3RDaGlsZC5jaGVja2Vk
LGIuYXBwZW5kQ2hlY2tlZD1pLmNoZWNrZWQsai5yZW1vdmVDaGlsZChpKSxqLmFwcGVuZENoaWxk
KHApO2lmKHAuYXR0YWNoRXZlbnQpZm9yKG4gaW57c3VibWl0OjEsY2hhbmdlOjEsZm9jdXNpbjox
fSltPSJvbiIrbixvPW0gaW4gcCxvfHwocC5zZXRBdHRyaWJ1dGUobSwicmV0dXJuOyIpLG89dHlw
ZW9mIHBbbV09PSJmdW5jdGlvbiIpLGJbbisiQnViYmxlcyJdPW87ai5yZW1vdmVDaGlsZChwKSxq
PWc9aD1wPWk9bnVsbCxmKGZ1bmN0aW9uKCl7dmFyIGQsZSxnLGgsaSxqLGwsbSxuLHEscixzLHQs
dT1jLmdldEVsZW1lbnRzQnlUYWdOYW1lKCJib2R5IilbMF07IXV8fChtPTEsdD0icGFkZGluZzow
O21hcmdpbjowO2JvcmRlcjoiLHI9InBvc2l0aW9uOmFic29sdXRlO3RvcDowO2xlZnQ6MDt3aWR0
aDoxcHg7aGVpZ2h0OjFweDsiLHM9dCsiMDt2aXNpYmlsaXR5OmhpZGRlbjsiLG49InN0eWxlPSci
K3IrdCsiNXB4IHNvbGlkICMwMDA7IixxPSI8ZGl2ICIrbisiZGlzcGxheTpibG9jazsnPjxkaXYg
c3R5bGU9JyIrdCsiMDtkaXNwbGF5OmJsb2NrO292ZXJmbG93OmhpZGRlbjsnPjwvZGl2PjwvZGl2
PiIrIjx0YWJsZSAiK24rIicgY2VsbHBhZGRpbmc9JzAnIGNlbGxzcGFjaW5nPScwJz4iKyI8dHI+
PHRkPjwvdGQ+PC90cj48L3RhYmxlPiIsZD1jLmNyZWF0ZUVsZW1lbnQoImRpdiIpLGQuc3R5bGUu
Y3NzVGV4dD1zKyJ3aWR0aDowO2hlaWdodDowO3Bvc2l0aW9uOnN0YXRpYzt0b3A6MDttYXJnaW4t
dG9wOiIrbSsicHgiLHUuaW5zZXJ0QmVmb3JlKGQsdS5maXJzdENoaWxkKSxwPWMuY3JlYXRlRWxl
bWVudCgiZGl2IiksZC5hcHBlbmRDaGlsZChwKSxwLmlubmVySFRNTD0iPHRhYmxlPjx0cj48dGQg
c3R5bGU9JyIrdCsiMDtkaXNwbGF5Om5vbmUnPjwvdGQ+PHRkPnQ8L3RkPjwvdHI+PC90YWJsZT4i
LGs9cC5nZXRFbGVtZW50c0J5VGFnTmFtZSgidGQiKSxvPWtbMF0ub2Zmc2V0SGVpZ2h0PT09MCxr
WzBdLnN0eWxlLmRpc3BsYXk9IiIsa1sxXS5zdHlsZS5kaXNwbGF5PSJub25lIixiLnJlbGlhYmxl
SGlkZGVuT2Zmc2V0cz1vJiZrWzBdLm9mZnNldEhlaWdodD09PTAsYS5nZXRDb21wdXRlZFN0eWxl
JiYocC5pbm5lckhUTUw9IiIsbD1jLmNyZWF0ZUVsZW1lbnQoImRpdiIpLGwuc3R5bGUud2lkdGg9
IjAiLGwuc3R5bGUubWFyZ2luUmlnaHQ9IjAiLHAuc3R5bGUud2lkdGg9IjJweCIscC5hcHBlbmRD
aGlsZChsKSxiLnJlbGlhYmxlTWFyZ2luUmlnaHQ9KHBhcnNlSW50KChhLmdldENvbXB1dGVkU3R5
bGUobCxudWxsKXx8e21hcmdpblJpZ2h0OjB9KS5tYXJnaW5SaWdodCwxMCl8fDApPT09MCksdHlw
ZW9mIHAuc3R5bGUuem9vbSE9InVuZGVmaW5lZCImJihwLmlubmVySFRNTD0iIixwLnN0eWxlLndp
ZHRoPXAuc3R5bGUucGFkZGluZz0iMXB4IixwLnN0eWxlLmJvcmRlcj0wLHAuc3R5bGUub3ZlcmZs
b3c9ImhpZGRlbiIscC5zdHlsZS5kaXNwbGF5PSJpbmxpbmUiLHAuc3R5bGUuem9vbT0xLGIuaW5s
aW5lQmxvY2tOZWVkc0xheW91dD1wLm9mZnNldFdpZHRoPT09MyxwLnN0eWxlLmRpc3BsYXk9ImJs
b2NrIixwLnN0eWxlLm92ZXJmbG93PSJ2aXNpYmxlIixwLmlubmVySFRNTD0iPGRpdiBzdHlsZT0n
d2lkdGg6NXB4Oyc+PC9kaXY+IixiLnNocmlua1dyYXBCbG9ja3M9cC5vZmZzZXRXaWR0aCE9PTMp
LHAuc3R5bGUuY3NzVGV4dD1yK3MscC5pbm5lckhUTUw9cSxlPXAuZmlyc3RDaGlsZCxnPWUuZmly
c3RDaGlsZCxpPWUubmV4dFNpYmxpbmcuZmlyc3RDaGlsZC5maXJzdENoaWxkLGo9e2RvZXNOb3RB
ZGRCb3JkZXI6Zy5vZmZzZXRUb3AhPT01LGRvZXNBZGRCb3JkZXJGb3JUYWJsZUFuZENlbGxzOmku
b2Zmc2V0VG9wPT09NX0sZy5zdHlsZS5wb3NpdGlvbj0iZml4ZWQiLGcuc3R5bGUudG9wPSIyMHB4
IixqLmZpeGVkUG9zaXRpb249Zy5vZmZzZXRUb3A9PT0yMHx8Zy5vZmZzZXRUb3A9PT0xNSxnLnN0
eWxlLnBvc2l0aW9uPWcuc3R5bGUudG9wPSIiLGUuc3R5bGUub3ZlcmZsb3c9ImhpZGRlbiIsZS5z
dHlsZS5wb3NpdGlvbj0icmVsYXRpdmUiLGouc3VidHJhY3RzQm9yZGVyRm9yT3ZlcmZsb3dOb3RW
aXNpYmxlPWcub2Zmc2V0VG9wPT09LTUsai5kb2VzTm90SW5jbHVkZU1hcmdpbkluQm9keU9mZnNl
dD11Lm9mZnNldFRvcCE9PW0sYS5nZXRDb21wdXRlZFN0eWxlJiYocC5zdHlsZS5tYXJnaW5Ub3A9
IjElIixiLnBpeGVsTWFyZ2luPShhLmdldENvbXB1dGVkU3R5bGUocCxudWxsKXx8e21hcmdpblRv
cDowfSkubWFyZ2luVG9wIT09IjElIiksdHlwZW9mIGQuc3R5bGUuem9vbSE9InVuZGVmaW5lZCIm
JihkLnN0eWxlLnpvb209MSksdS5yZW1vdmVDaGlsZChkKSxsPXA9ZD1udWxsLGYuZXh0ZW5kKGIs
aikpfSk7cmV0dXJuIGJ9KCk7dmFyIGo9L14oPzpcey4qXH18XFsuKlxdKSQvLGs9LyhbQS1aXSkv
ZztmLmV4dGVuZCh7Y2FjaGU6e30sdXVpZDowLGV4cGFuZG86ImpRdWVyeSIrKGYuZm4uanF1ZXJ5
K01hdGgucmFuZG9tKCkpLnJlcGxhY2UoL1xEL2csIiIpLG5vRGF0YTp7ZW1iZWQ6ITAsb2JqZWN0
OiJjbHNpZDpEMjdDREI2RS1BRTZELTExY2YtOTZCOC00NDQ1NTM1NDAwMDAiLGFwcGxldDohMH0s
aGFzRGF0YTpmdW5jdGlvbihhKXthPWEubm9kZVR5cGU/Zi5jYWNoZVthW2YuZXhwYW5kb11dOmFb
Zi5leHBhbmRvXTtyZXR1cm4hIWEmJiFtKGEpfSxkYXRhOmZ1bmN0aW9uKGEsYyxkLGUpe2lmKCEh
Zi5hY2NlcHREYXRhKGEpKXt2YXIgZyxoLGksaj1mLmV4cGFuZG8saz10eXBlb2YgYz09InN0cmlu
ZyIsbD1hLm5vZGVUeXBlLG09bD9mLmNhY2hlOmEsbj1sP2Fbal06YVtqXSYmaixvPWM9PT0iZXZl
bnRzIjtpZigoIW58fCFtW25dfHwhbyYmIWUmJiFtW25dLmRhdGEpJiZrJiZkPT09YilyZXR1cm47
bnx8KGw/YVtqXT1uPSsrZi51dWlkOm49aiksbVtuXXx8KG1bbl09e30sbHx8KG1bbl0udG9KU09O
PWYubm9vcCkpO2lmKHR5cGVvZiBjPT0ib2JqZWN0Inx8dHlwZW9mIGM9PSJmdW5jdGlvbiIpZT9t
W25dPWYuZXh0ZW5kKG1bbl0sYyk6bVtuXS5kYXRhPWYuZXh0ZW5kKG1bbl0uZGF0YSxjKTtnPWg9
bVtuXSxlfHwoaC5kYXRhfHwoaC5kYXRhPXt9KSxoPWguZGF0YSksZCE9PWImJihoW2YuY2FtZWxD
YXNlKGMpXT1kKTtpZihvJiYhaFtjXSlyZXR1cm4gZy5ldmVudHM7az8oaT1oW2NdLGk9PW51bGwm
JihpPWhbZi5jYW1lbENhc2UoYyldKSk6aT1oO3JldHVybiBpfX0scmVtb3ZlRGF0YTpmdW5jdGlv
bihhLGIsYyl7aWYoISFmLmFjY2VwdERhdGEoYSkpe3ZhciBkLGUsZyxoPWYuZXhwYW5kbyxpPWEu
bm9kZVR5cGUsaj1pP2YuY2FjaGU6YSxrPWk/YVtoXTpoO2lmKCFqW2tdKXJldHVybjtpZihiKXtk
PWM/altrXTpqW2tdLmRhdGE7aWYoZCl7Zi5pc0FycmF5KGIpfHwoYiBpbiBkP2I9W2JdOihiPWYu
Y2FtZWxDYXNlKGIpLGIgaW4gZD9iPVtiXTpiPWIuc3BsaXQoIiAiKSkpO2ZvcihlPTAsZz1iLmxl
bmd0aDtlPGc7ZSsrKWRlbGV0ZSBkW2JbZV1dO2lmKCEoYz9tOmYuaXNFbXB0eU9iamVjdCkoZCkp
cmV0dXJufX1pZighYyl7ZGVsZXRlIGpba10uZGF0YTtpZighbShqW2tdKSlyZXR1cm59Zi5zdXBw
b3J0LmRlbGV0ZUV4cGFuZG98fCFqLnNldEludGVydmFsP2RlbGV0ZSBqW2tdOmpba109bnVsbCxp
JiYoZi5zdXBwb3J0LmRlbGV0ZUV4cGFuZG8/ZGVsZXRlIGFbaF06YS5yZW1vdmVBdHRyaWJ1dGU/
YS5yZW1vdmVBdHRyaWJ1dGUoaCk6YVtoXT1udWxsKX19LF9kYXRhOmZ1bmN0aW9uKGEsYixjKXty
ZXR1cm4gZi5kYXRhKGEsYixjLCEwKX0sYWNjZXB0RGF0YTpmdW5jdGlvbihhKXtpZihhLm5vZGVO
YW1lKXt2YXIgYj1mLm5vRGF0YVthLm5vZGVOYW1lLnRvTG93ZXJDYXNlKCldO2lmKGIpcmV0dXJu
IGIhPT0hMCYmYS5nZXRBdHRyaWJ1dGUoImNsYXNzaWQiKT09PWJ9cmV0dXJuITB9fSksZi5mbi5l
eHRlbmQoe2RhdGE6ZnVuY3Rpb24oYSxjKXt2YXIgZCxlLGcsaCxpLGo9dGhpc1swXSxrPTAsbT1u
dWxsO2lmKGE9PT1iKXtpZih0aGlzLmxlbmd0aCl7bT1mLmRhdGEoaik7aWYoai5ub2RlVHlwZT09
PTEmJiFmLl9kYXRhKGosInBhcnNlZEF0dHJzIikpe2c9ai5hdHRyaWJ1dGVzO2ZvcihpPWcubGVu
Z3RoO2s8aTtrKyspaD1nW2tdLm5hbWUsaC5pbmRleE9mKCJkYXRhLSIpPT09MCYmKGg9Zi5jYW1l
bENhc2UoaC5zdWJzdHJpbmcoNSkpLGwoaixoLG1baF0pKTtmLl9kYXRhKGosInBhcnNlZEF0dHJz
IiwhMCl9fXJldHVybiBtfWlmKHR5cGVvZiBhPT0ib2JqZWN0IilyZXR1cm4gdGhpcy5lYWNoKGZ1
bmN0aW9uKCl7Zi5kYXRhKHRoaXMsYSl9KTtkPWEuc3BsaXQoIi4iLDIpLGRbMV09ZFsxXT8iLiIr
ZFsxXToiIixlPWRbMV0rIiEiO3JldHVybiBmLmFjY2Vzcyh0aGlzLGZ1bmN0aW9uKGMpe2lmKGM9
PT1iKXttPXRoaXMudHJpZ2dlckhhbmRsZXIoImdldERhdGEiK2UsW2RbMF1dKSxtPT09YiYmaiYm
KG09Zi5kYXRhKGosYSksbT1sKGosYSxtKSk7cmV0dXJuIG09PT1iJiZkWzFdP3RoaXMuZGF0YShk
WzBdKTptfWRbMV09Yyx0aGlzLmVhY2goZnVuY3Rpb24oKXt2YXIgYj1mKHRoaXMpO2IudHJpZ2dl
ckhhbmRsZXIoInNldERhdGEiK2UsZCksZi5kYXRhKHRoaXMsYSxjKSxiLnRyaWdnZXJIYW5kbGVy
KCJjaGFuZ2VEYXRhIitlLGQpfSl9LG51bGwsYyxhcmd1bWVudHMubGVuZ3RoPjEsbnVsbCwhMSl9
LHJlbW92ZURhdGE6ZnVuY3Rpb24oYSl7cmV0dXJuIHRoaXMuZWFjaChmdW5jdGlvbigpe2YucmVt
b3ZlRGF0YSh0aGlzLGEpfSl9fSksZi5leHRlbmQoe19tYXJrOmZ1bmN0aW9uKGEsYil7YSYmKGI9
KGJ8fCJmeCIpKyJtYXJrIixmLl9kYXRhKGEsYiwoZi5fZGF0YShhLGIpfHwwKSsxKSl9LF91bm1h
cms6ZnVuY3Rpb24oYSxiLGMpe2EhPT0hMCYmKGM9YixiPWEsYT0hMSk7aWYoYil7Yz1jfHwiZngi
O3ZhciBkPWMrIm1hcmsiLGU9YT8wOihmLl9kYXRhKGIsZCl8fDEpLTE7ZT9mLl9kYXRhKGIsZCxl
KTooZi5yZW1vdmVEYXRhKGIsZCwhMCksbihiLGMsIm1hcmsiKSl9fSxxdWV1ZTpmdW5jdGlvbihh
LGIsYyl7dmFyIGQ7aWYoYSl7Yj0oYnx8ImZ4IikrInF1ZXVlIixkPWYuX2RhdGEoYSxiKSxjJiYo
IWR8fGYuaXNBcnJheShjKT9kPWYuX2RhdGEoYSxiLGYubWFrZUFycmF5KGMpKTpkLnB1c2goYykp
O3JldHVybiBkfHxbXX19LGRlcXVldWU6ZnVuY3Rpb24oYSxiKXtiPWJ8fCJmeCI7dmFyIGM9Zi5x
dWV1ZShhLGIpLGQ9Yy5zaGlmdCgpLGU9e307ZD09PSJpbnByb2dyZXNzIiYmKGQ9Yy5zaGlmdCgp
KSxkJiYoYj09PSJmeCImJmMudW5zaGlmdCgiaW5wcm9ncmVzcyIpLGYuX2RhdGEoYSxiKyIucnVu
IixlKSxkLmNhbGwoYSxmdW5jdGlvbigpe2YuZGVxdWV1ZShhLGIpfSxlKSksYy5sZW5ndGh8fChm
LnJlbW92ZURhdGEoYSxiKyJxdWV1ZSAiK2IrIi5ydW4iLCEwKSxuKGEsYiwicXVldWUiKSl9fSks
Zi5mbi5leHRlbmQoe3F1ZXVlOmZ1bmN0aW9uKGEsYyl7dmFyIGQ9Mjt0eXBlb2YgYSE9InN0cmlu
ZyImJihjPWEsYT0iZngiLGQtLSk7aWYoYXJndW1lbnRzLmxlbmd0aDxkKXJldHVybiBmLnF1ZXVl
KHRoaXNbMF0sYSk7cmV0dXJuIGM9PT1iP3RoaXM6dGhpcy5lYWNoKGZ1bmN0aW9uKCl7dmFyIGI9
Zi5xdWV1ZSh0aGlzLGEsYyk7YT09PSJmeCImJmJbMF0hPT0iaW5wcm9ncmVzcyImJmYuZGVxdWV1
ZSh0aGlzLGEpfSl9LGRlcXVldWU6ZnVuY3Rpb24oYSl7cmV0dXJuIHRoaXMuZWFjaChmdW5jdGlv
bigpe2YuZGVxdWV1ZSh0aGlzLGEpfSl9LGRlbGF5OmZ1bmN0aW9uKGEsYil7YT1mLmZ4P2YuZngu
c3BlZWRzW2FdfHxhOmEsYj1ifHwiZngiO3JldHVybiB0aGlzLnF1ZXVlKGIsZnVuY3Rpb24oYixj
KXt2YXIgZD1zZXRUaW1lb3V0KGIsYSk7Yy5zdG9wPWZ1bmN0aW9uKCl7Y2xlYXJUaW1lb3V0KGQp
fX0pfSxjbGVhclF1ZXVlOmZ1bmN0aW9uKGEpe3JldHVybiB0aGlzLnF1ZXVlKGF8fCJmeCIsW10p
fSxwcm9taXNlOmZ1bmN0aW9uKGEsYyl7ZnVuY3Rpb24gbSgpey0taHx8ZC5yZXNvbHZlV2l0aChl
LFtlXSl9dHlwZW9mIGEhPSJzdHJpbmciJiYoYz1hLGE9YiksYT1hfHwiZngiO3ZhciBkPWYuRGVm
ZXJyZWQoKSxlPXRoaXMsZz1lLmxlbmd0aCxoPTEsaT1hKyJkZWZlciIsaj1hKyJxdWV1ZSIsaz1h
KyJtYXJrIixsO3doaWxlKGctLSlpZihsPWYuZGF0YShlW2ddLGksYiwhMCl8fChmLmRhdGEoZVtn
XSxqLGIsITApfHxmLmRhdGEoZVtnXSxrLGIsITApKSYmZi5kYXRhKGVbZ10saSxmLkNhbGxiYWNr
cygib25jZSBtZW1vcnkiKSwhMCkpaCsrLGwuYWRkKG0pO20oKTtyZXR1cm4gZC5wcm9taXNlKGMp
fX0pO3ZhciBvPS9bXG5cdFxyXS9nLHA9L1xzKy8scT0vXHIvZyxyPS9eKD86YnV0dG9ufGlucHV0
KSQvaSxzPS9eKD86YnV0dG9ufGlucHV0fG9iamVjdHxzZWxlY3R8dGV4dGFyZWEpJC9pLHQ9L15h
KD86cmVhKT8kL2ksdT0vXig/OmF1dG9mb2N1c3xhdXRvcGxheXxhc3luY3xjaGVja2VkfGNvbnRy
b2xzfGRlZmVyfGRpc2FibGVkfGhpZGRlbnxsb29wfG11bHRpcGxlfG9wZW58cmVhZG9ubHl8cmVx
dWlyZWR8c2NvcGVkfHNlbGVjdGVkKSQvaSx2PWYuc3VwcG9ydC5nZXRTZXRBdHRyaWJ1dGUsdyx4
LHk7Zi5mbi5leHRlbmQoe2F0dHI6ZnVuY3Rpb24oYSxiKXtyZXR1cm4gZi5hY2Nlc3ModGhpcyxm
LmF0dHIsYSxiLGFyZ3VtZW50cy5sZW5ndGg+MSl9LHJlbW92ZUF0dHI6ZnVuY3Rpb24oYSl7cmV0
dXJuIHRoaXMuZWFjaChmdW5jdGlvbigpe2YucmVtb3ZlQXR0cih0aGlzLGEpfSl9LHByb3A6ZnVu
Y3Rpb24oYSxiKXtyZXR1cm4gZi5hY2Nlc3ModGhpcyxmLnByb3AsYSxiLGFyZ3VtZW50cy5sZW5n
dGg+MSl9LHJlbW92ZVByb3A6ZnVuY3Rpb24oYSl7YT1mLnByb3BGaXhbYV18fGE7cmV0dXJuIHRo
aXMuZWFjaChmdW5jdGlvbigpe3RyeXt0aGlzW2FdPWIsZGVsZXRlIHRoaXNbYV19Y2F0Y2goYyl7
fX0pfSxhZGRDbGFzczpmdW5jdGlvbihhKXt2YXIgYixjLGQsZSxnLGgsaTtpZihmLmlzRnVuY3Rp
b24oYSkpcmV0dXJuIHRoaXMuZWFjaChmdW5jdGlvbihiKXtmKHRoaXMpLmFkZENsYXNzKGEuY2Fs
bCh0aGlzLGIsdGhpcy5jbGFzc05hbWUpKX0pO2lmKGEmJnR5cGVvZiBhPT0ic3RyaW5nIil7Yj1h
LnNwbGl0KHApO2ZvcihjPTAsZD10aGlzLmxlbmd0aDtjPGQ7YysrKXtlPXRoaXNbY107aWYoZS5u
b2RlVHlwZT09PTEpaWYoIWUuY2xhc3NOYW1lJiZiLmxlbmd0aD09PTEpZS5jbGFzc05hbWU9YTtl
bHNle2c9IiAiK2UuY2xhc3NOYW1lKyIgIjtmb3IoaD0wLGk9Yi5sZW5ndGg7aDxpO2grKyl+Zy5p
bmRleE9mKCIgIitiW2hdKyIgIil8fChnKz1iW2hdKyIgIik7ZS5jbGFzc05hbWU9Zi50cmltKGcp
fX19cmV0dXJuIHRoaXN9LHJlbW92ZUNsYXNzOmZ1bmN0aW9uKGEpe3ZhciBjLGQsZSxnLGgsaSxq
O2lmKGYuaXNGdW5jdGlvbihhKSlyZXR1cm4gdGhpcy5lYWNoKGZ1bmN0aW9uKGIpe2YodGhpcyku
cmVtb3ZlQ2xhc3MoYS5jYWxsKHRoaXMsYix0aGlzLmNsYXNzTmFtZSkpfSk7aWYoYSYmdHlwZW9m
IGE9PSJzdHJpbmcifHxhPT09Yil7Yz0oYXx8IiIpLnNwbGl0KHApO2ZvcihkPTAsZT10aGlzLmxl
bmd0aDtkPGU7ZCsrKXtnPXRoaXNbZF07aWYoZy5ub2RlVHlwZT09PTEmJmcuY2xhc3NOYW1lKWlm
KGEpe2g9KCIgIitnLmNsYXNzTmFtZSsiICIpLnJlcGxhY2UobywiICIpO2ZvcihpPTAsaj1jLmxl
bmd0aDtpPGo7aSsrKWg9aC5yZXBsYWNlKCIgIitjW2ldKyIgIiwiICIpO2cuY2xhc3NOYW1lPWYu
dHJpbShoKX1lbHNlIGcuY2xhc3NOYW1lPSIifX1yZXR1cm4gdGhpc30sdG9nZ2xlQ2xhc3M6ZnVu
Y3Rpb24oYSxiKXt2YXIgYz10eXBlb2YgYSxkPXR5cGVvZiBiPT0iYm9vbGVhbiI7aWYoZi5pc0Z1
bmN0aW9uKGEpKXJldHVybiB0aGlzLmVhY2goZnVuY3Rpb24oYyl7Zih0aGlzKS50b2dnbGVDbGFz
cyhhLmNhbGwodGhpcyxjLHRoaXMuY2xhc3NOYW1lLGIpLGIpfSk7cmV0dXJuIHRoaXMuZWFjaChm
dW5jdGlvbigpe2lmKGM9PT0ic3RyaW5nIil7dmFyIGUsZz0wLGg9Zih0aGlzKSxpPWIsaj1hLnNw
bGl0KHApO3doaWxlKGU9altnKytdKWk9ZD9pOiFoLmhhc0NsYXNzKGUpLGhbaT8iYWRkQ2xhc3Mi
OiJyZW1vdmVDbGFzcyJdKGUpfWVsc2UgaWYoYz09PSJ1bmRlZmluZWQifHxjPT09ImJvb2xlYW4i
KXRoaXMuY2xhc3NOYW1lJiZmLl9kYXRhKHRoaXMsIl9fY2xhc3NOYW1lX18iLHRoaXMuY2xhc3NO
YW1lKSx0aGlzLmNsYXNzTmFtZT10aGlzLmNsYXNzTmFtZXx8YT09PSExPyIiOmYuX2RhdGEodGhp
cywiX19jbGFzc05hbWVfXyIpfHwiIn0pfSxoYXNDbGFzczpmdW5jdGlvbihhKXt2YXIgYj0iICIr
YSsiICIsYz0wLGQ9dGhpcy5sZW5ndGg7Zm9yKDtjPGQ7YysrKWlmKHRoaXNbY10ubm9kZVR5cGU9
PT0xJiYoIiAiK3RoaXNbY10uY2xhc3NOYW1lKyIgIikucmVwbGFjZShvLCIgIikuaW5kZXhPZihi
KT4tMSlyZXR1cm4hMDtyZXR1cm4hMX0sdmFsOmZ1bmN0aW9uKGEpe3ZhciBjLGQsZSxnPXRoaXNb
MF07e2lmKCEhYXJndW1lbnRzLmxlbmd0aCl7ZT1mLmlzRnVuY3Rpb24oYSk7cmV0dXJuIHRoaXMu
ZWFjaChmdW5jdGlvbihkKXt2YXIgZz1mKHRoaXMpLGg7aWYodGhpcy5ub2RlVHlwZT09PTEpe2U/
aD1hLmNhbGwodGhpcyxkLGcudmFsKCkpOmg9YSxoPT1udWxsP2g9IiI6dHlwZW9mIGg9PSJudW1i
ZXIiP2grPSIiOmYuaXNBcnJheShoKSYmKGg9Zi5tYXAoaCxmdW5jdGlvbihhKXtyZXR1cm4gYT09
bnVsbD8iIjphKyIifSkpLGM9Zi52YWxIb29rc1t0aGlzLnR5cGVdfHxmLnZhbEhvb2tzW3RoaXMu
bm9kZU5hbWUudG9Mb3dlckNhc2UoKV07aWYoIWN8fCEoInNldCJpbiBjKXx8Yy5zZXQodGhpcyxo
LCJ2YWx1ZSIpPT09Yil0aGlzLnZhbHVlPWh9fSl9aWYoZyl7Yz1mLnZhbEhvb2tzW2cudHlwZV18
fGYudmFsSG9va3NbZy5ub2RlTmFtZS50b0xvd2VyQ2FzZSgpXTtpZihjJiYiZ2V0ImluIGMmJihk
PWMuZ2V0KGcsInZhbHVlIikpIT09YilyZXR1cm4gZDtkPWcudmFsdWU7cmV0dXJuIHR5cGVvZiBk
PT0ic3RyaW5nIj9kLnJlcGxhY2UocSwiIik6ZD09bnVsbD8iIjpkfX19fSksZi5leHRlbmQoe3Zh
bEhvb2tzOntvcHRpb246e2dldDpmdW5jdGlvbihhKXt2YXIgYj1hLmF0dHJpYnV0ZXMudmFsdWU7
cmV0dXJuIWJ8fGIuc3BlY2lmaWVkP2EudmFsdWU6YS50ZXh0fX0sc2VsZWN0OntnZXQ6ZnVuY3Rp
b24oYSl7dmFyIGIsYyxkLGUsZz1hLnNlbGVjdGVkSW5kZXgsaD1bXSxpPWEub3B0aW9ucyxqPWEu
dHlwZT09PSJzZWxlY3Qtb25lIjtpZihnPDApcmV0dXJuIG51bGw7Yz1qP2c6MCxkPWo/ZysxOmku
bGVuZ3RoO2Zvcig7YzxkO2MrKyl7ZT1pW2NdO2lmKGUuc2VsZWN0ZWQmJihmLnN1cHBvcnQub3B0
RGlzYWJsZWQ/IWUuZGlzYWJsZWQ6ZS5nZXRBdHRyaWJ1dGUoImRpc2FibGVkIik9PT1udWxsKSYm
KCFlLnBhcmVudE5vZGUuZGlzYWJsZWR8fCFmLm5vZGVOYW1lKGUucGFyZW50Tm9kZSwib3B0Z3Jv
dXAiKSkpe2I9ZihlKS52YWwoKTtpZihqKXJldHVybiBiO2gucHVzaChiKX19aWYoaiYmIWgubGVu
Z3RoJiZpLmxlbmd0aClyZXR1cm4gZihpW2ddKS52YWwoKTtyZXR1cm4gaH0sc2V0OmZ1bmN0aW9u
KGEsYil7dmFyIGM9Zi5tYWtlQXJyYXkoYik7ZihhKS5maW5kKCJvcHRpb24iKS5lYWNoKGZ1bmN0
aW9uKCl7dGhpcy5zZWxlY3RlZD1mLmluQXJyYXkoZih0aGlzKS52YWwoKSxjKT49MH0pLGMubGVu
Z3RofHwoYS5zZWxlY3RlZEluZGV4PS0xKTtyZXR1cm4gY319fSxhdHRyRm46e3ZhbDohMCxjc3M6
ITAsaHRtbDohMCx0ZXh0OiEwLGRhdGE6ITAsd2lkdGg6ITAsaGVpZ2h0OiEwLG9mZnNldDohMH0s
YXR0cjpmdW5jdGlvbihhLGMsZCxlKXt2YXIgZyxoLGksaj1hLm5vZGVUeXBlO2lmKCEhYSYmaiE9
PTMmJmohPT04JiZqIT09Mil7aWYoZSYmYyBpbiBmLmF0dHJGbilyZXR1cm4gZihhKVtjXShkKTtp
Zih0eXBlb2YgYS5nZXRBdHRyaWJ1dGU9PSJ1bmRlZmluZWQiKXJldHVybiBmLnByb3AoYSxjLGQp
O2k9aiE9PTF8fCFmLmlzWE1MRG9jKGEpLGkmJihjPWMudG9Mb3dlckNhc2UoKSxoPWYuYXR0ckhv
b2tzW2NdfHwodS50ZXN0KGMpP3g6dykpO2lmKGQhPT1iKXtpZihkPT09bnVsbCl7Zi5yZW1vdmVB
dHRyKGEsYyk7cmV0dXJufWlmKGgmJiJzZXQiaW4gaCYmaSYmKGc9aC5zZXQoYSxkLGMpKSE9PWIp
cmV0dXJuIGc7YS5zZXRBdHRyaWJ1dGUoYywiIitkKTtyZXR1cm4gZH1pZihoJiYiZ2V0ImluIGgm
JmkmJihnPWguZ2V0KGEsYykpIT09bnVsbClyZXR1cm4gZztnPWEuZ2V0QXR0cmlidXRlKGMpO3Jl
dHVybiBnPT09bnVsbD9iOmd9fSxyZW1vdmVBdHRyOmZ1bmN0aW9uKGEsYil7dmFyIGMsZCxlLGcs
aCxpPTA7aWYoYiYmYS5ub2RlVHlwZT09PTEpe2Q9Yi50b0xvd2VyQ2FzZSgpLnNwbGl0KHApLGc9
ZC5sZW5ndGg7Zm9yKDtpPGc7aSsrKWU9ZFtpXSxlJiYoYz1mLnByb3BGaXhbZV18fGUsaD11LnRl
c3QoZSksaHx8Zi5hdHRyKGEsZSwiIiksYS5yZW1vdmVBdHRyaWJ1dGUodj9lOmMpLGgmJmMgaW4g
YSYmKGFbY109ITEpKX19LGF0dHJIb29rczp7dHlwZTp7c2V0OmZ1bmN0aW9uKGEsYil7aWYoci50
ZXN0KGEubm9kZU5hbWUpJiZhLnBhcmVudE5vZGUpZi5lcnJvcigidHlwZSBwcm9wZXJ0eSBjYW4n
dCBiZSBjaGFuZ2VkIik7ZWxzZSBpZighZi5zdXBwb3J0LnJhZGlvVmFsdWUmJmI9PT0icmFkaW8i
JiZmLm5vZGVOYW1lKGEsImlucHV0Iikpe3ZhciBjPWEudmFsdWU7YS5zZXRBdHRyaWJ1dGUoInR5
cGUiLGIpLGMmJihhLnZhbHVlPWMpO3JldHVybiBifX19LHZhbHVlOntnZXQ6ZnVuY3Rpb24oYSxi
KXtpZih3JiZmLm5vZGVOYW1lKGEsImJ1dHRvbiIpKXJldHVybiB3LmdldChhLGIpO3JldHVybiBi
IGluIGE/YS52YWx1ZTpudWxsfSxzZXQ6ZnVuY3Rpb24oYSxiLGMpe2lmKHcmJmYubm9kZU5hbWUo
YSwiYnV0dG9uIikpcmV0dXJuIHcuc2V0KGEsYixjKTthLnZhbHVlPWJ9fX0scHJvcEZpeDp7dGFi
aW5kZXg6InRhYkluZGV4IixyZWFkb25seToicmVhZE9ubHkiLCJmb3IiOiJodG1sRm9yIiwiY2xh
c3MiOiJjbGFzc05hbWUiLG1heGxlbmd0aDoibWF4TGVuZ3RoIixjZWxsc3BhY2luZzoiY2VsbFNw
YWNpbmciLGNlbGxwYWRkaW5nOiJjZWxsUGFkZGluZyIscm93c3Bhbjoicm93U3BhbiIsY29sc3Bh
bjoiY29sU3BhbiIsdXNlbWFwOiJ1c2VNYXAiLGZyYW1lYm9yZGVyOiJmcmFtZUJvcmRlciIsY29u
dGVudGVkaXRhYmxlOiJjb250ZW50RWRpdGFibGUifSxwcm9wOmZ1bmN0aW9uKGEsYyxkKXt2YXIg
ZSxnLGgsaT1hLm5vZGVUeXBlO2lmKCEhYSYmaSE9PTMmJmkhPT04JiZpIT09Mil7aD1pIT09MXx8
IWYuaXNYTUxEb2MoYSksaCYmKGM9Zi5wcm9wRml4W2NdfHxjLGc9Zi5wcm9wSG9va3NbY10pO3Jl
dHVybiBkIT09Yj9nJiYic2V0ImluIGcmJihlPWcuc2V0KGEsZCxjKSkhPT1iP2U6YVtjXT1kOmcm
JiJnZXQiaW4gZyYmKGU9Zy5nZXQoYSxjKSkhPT1udWxsP2U6YVtjXX19LHByb3BIb29rczp7dGFi
SW5kZXg6e2dldDpmdW5jdGlvbihhKXt2YXIgYz1hLmdldEF0dHJpYnV0ZU5vZGUoInRhYmluZGV4
Iik7cmV0dXJuIGMmJmMuc3BlY2lmaWVkP3BhcnNlSW50KGMudmFsdWUsMTApOnMudGVzdChhLm5v
ZGVOYW1lKXx8dC50ZXN0KGEubm9kZU5hbWUpJiZhLmhyZWY/MDpifX19fSksZi5hdHRySG9va3Mu
dGFiaW5kZXg9Zi5wcm9wSG9va3MudGFiSW5kZXgseD17Z2V0OmZ1bmN0aW9uKGEsYyl7dmFyIGQs
ZT1mLnByb3AoYSxjKTtyZXR1cm4gZT09PSEwfHx0eXBlb2YgZSE9ImJvb2xlYW4iJiYoZD1hLmdl
dEF0dHJpYnV0ZU5vZGUoYykpJiZkLm5vZGVWYWx1ZSE9PSExP2MudG9Mb3dlckNhc2UoKTpifSxz
ZXQ6ZnVuY3Rpb24oYSxiLGMpe3ZhciBkO2I9PT0hMT9mLnJlbW92ZUF0dHIoYSxjKTooZD1mLnBy
b3BGaXhbY118fGMsZCBpbiBhJiYoYVtkXT0hMCksYS5zZXRBdHRyaWJ1dGUoYyxjLnRvTG93ZXJD
YXNlKCkpKTtyZXR1cm4gY319LHZ8fCh5PXtuYW1lOiEwLGlkOiEwLGNvb3JkczohMH0sdz1mLnZh
bEhvb2tzLmJ1dHRvbj17Z2V0OmZ1bmN0aW9uKGEsYyl7dmFyIGQ7ZD1hLmdldEF0dHJpYnV0ZU5v
ZGUoYyk7cmV0dXJuIGQmJih5W2NdP2Qubm9kZVZhbHVlIT09IiI6ZC5zcGVjaWZpZWQpP2Qubm9k
ZVZhbHVlOmJ9LHNldDpmdW5jdGlvbihhLGIsZCl7dmFyIGU9YS5nZXRBdHRyaWJ1dGVOb2RlKGQp
O2V8fChlPWMuY3JlYXRlQXR0cmlidXRlKGQpLGEuc2V0QXR0cmlidXRlTm9kZShlKSk7cmV0dXJu
IGUubm9kZVZhbHVlPWIrIiJ9fSxmLmF0dHJIb29rcy50YWJpbmRleC5zZXQ9dy5zZXQsZi5lYWNo
KFsid2lkdGgiLCJoZWlnaHQiXSxmdW5jdGlvbihhLGIpe2YuYXR0ckhvb2tzW2JdPWYuZXh0ZW5k
KGYuYXR0ckhvb2tzW2JdLHtzZXQ6ZnVuY3Rpb24oYSxjKXtpZihjPT09IiIpe2Euc2V0QXR0cmli
dXRlKGIsImF1dG8iKTtyZXR1cm4gY319fSl9KSxmLmF0dHJIb29rcy5jb250ZW50ZWRpdGFibGU9
e2dldDp3LmdldCxzZXQ6ZnVuY3Rpb24oYSxiLGMpe2I9PT0iIiYmKGI9ImZhbHNlIiksdy5zZXQo
YSxiLGMpfX0pLGYuc3VwcG9ydC5ocmVmTm9ybWFsaXplZHx8Zi5lYWNoKFsiaHJlZiIsInNyYyIs
IndpZHRoIiwiaGVpZ2h0Il0sZnVuY3Rpb24oYSxjKXtmLmF0dHJIb29rc1tjXT1mLmV4dGVuZChm
LmF0dHJIb29rc1tjXSx7Z2V0OmZ1bmN0aW9uKGEpe3ZhciBkPWEuZ2V0QXR0cmlidXRlKGMsMik7
cmV0dXJuIGQ9PT1udWxsP2I6ZH19KX0pLGYuc3VwcG9ydC5zdHlsZXx8KGYuYXR0ckhvb2tzLnN0
eWxlPXtnZXQ6ZnVuY3Rpb24oYSl7cmV0dXJuIGEuc3R5bGUuY3NzVGV4dC50b0xvd2VyQ2FzZSgp
fHxifSxzZXQ6ZnVuY3Rpb24oYSxiKXtyZXR1cm4gYS5zdHlsZS5jc3NUZXh0PSIiK2J9fSksZi5z
dXBwb3J0Lm9wdFNlbGVjdGVkfHwoZi5wcm9wSG9va3Muc2VsZWN0ZWQ9Zi5leHRlbmQoZi5wcm9w
SG9va3Muc2VsZWN0ZWQse2dldDpmdW5jdGlvbihhKXt2YXIgYj1hLnBhcmVudE5vZGU7YiYmKGIu
c2VsZWN0ZWRJbmRleCxiLnBhcmVudE5vZGUmJmIucGFyZW50Tm9kZS5zZWxlY3RlZEluZGV4KTty
ZXR1cm4gbnVsbH19KSksZi5zdXBwb3J0LmVuY3R5cGV8fChmLnByb3BGaXguZW5jdHlwZT0iZW5j
b2RpbmciKSxmLnN1cHBvcnQuY2hlY2tPbnx8Zi5lYWNoKFsicmFkaW8iLCJjaGVja2JveCJdLGZ1
bmN0aW9uKCl7Zi52YWxIb29rc1t0aGlzXT17Z2V0OmZ1bmN0aW9uKGEpe3JldHVybiBhLmdldEF0
dHJpYnV0ZSgidmFsdWUiKT09PW51bGw/Im9uIjphLnZhbHVlfX19KSxmLmVhY2goWyJyYWRpbyIs
ImNoZWNrYm94Il0sZnVuY3Rpb24oKXtmLnZhbEhvb2tzW3RoaXNdPWYuZXh0ZW5kKGYudmFsSG9v
a3NbdGhpc10se3NldDpmdW5jdGlvbihhLGIpe2lmKGYuaXNBcnJheShiKSlyZXR1cm4gYS5jaGVj
a2VkPWYuaW5BcnJheShmKGEpLnZhbCgpLGIpPj0wfX0pfSk7dmFyIHo9L14oPzp0ZXh0YXJlYXxp
bnB1dHxzZWxlY3QpJC9pLEE9L14oW15cLl0qKT8oPzpcLiguKykpPyQvLEI9Lyg/Ol58XHMpaG92
ZXIoXC5cUyspP1xiLyxDPS9ea2V5LyxEPS9eKD86bW91c2V8Y29udGV4dG1lbnUpfGNsaWNrLyxF
PS9eKD86Zm9jdXNpbmZvY3VzfGZvY3Vzb3V0Ymx1cikkLyxGPS9eKFx3KikoPzojKFtcd1wtXSsp
KT8oPzpcLihbXHdcLV0rKSk/JC8sRz1mdW5jdGlvbigKYSl7dmFyIGI9Ri5leGVjKGEpO2ImJihi
WzFdPShiWzFdfHwiIikudG9Mb3dlckNhc2UoKSxiWzNdPWJbM10mJm5ldyBSZWdFeHAoIig/Ol58
XFxzKSIrYlszXSsiKD86XFxzfCQpIikpO3JldHVybiBifSxIPWZ1bmN0aW9uKGEsYil7dmFyIGM9
YS5hdHRyaWJ1dGVzfHx7fTtyZXR1cm4oIWJbMV18fGEubm9kZU5hbWUudG9Mb3dlckNhc2UoKT09
PWJbMV0pJiYoIWJbMl18fChjLmlkfHx7fSkudmFsdWU9PT1iWzJdKSYmKCFiWzNdfHxiWzNdLnRl
c3QoKGNbImNsYXNzIl18fHt9KS52YWx1ZSkpfSxJPWZ1bmN0aW9uKGEpe3JldHVybiBmLmV2ZW50
LnNwZWNpYWwuaG92ZXI/YTphLnJlcGxhY2UoQiwibW91c2VlbnRlciQxIG1vdXNlbGVhdmUkMSIp
fTtmLmV2ZW50PXthZGQ6ZnVuY3Rpb24oYSxjLGQsZSxnKXt2YXIgaCxpLGosayxsLG0sbixvLHAs
cSxyLHM7aWYoIShhLm5vZGVUeXBlPT09M3x8YS5ub2RlVHlwZT09PTh8fCFjfHwhZHx8IShoPWYu
X2RhdGEoYSkpKSl7ZC5oYW5kbGVyJiYocD1kLGQ9cC5oYW5kbGVyLGc9cC5zZWxlY3RvciksZC5n
dWlkfHwoZC5ndWlkPWYuZ3VpZCsrKSxqPWguZXZlbnRzLGp8fChoLmV2ZW50cz1qPXt9KSxpPWgu
aGFuZGxlLGl8fChoLmhhbmRsZT1pPWZ1bmN0aW9uKGEpe3JldHVybiB0eXBlb2YgZiE9InVuZGVm
aW5lZCImJighYXx8Zi5ldmVudC50cmlnZ2VyZWQhPT1hLnR5cGUpP2YuZXZlbnQuZGlzcGF0Y2gu
YXBwbHkoaS5lbGVtLGFyZ3VtZW50cyk6Yn0saS5lbGVtPWEpLGM9Zi50cmltKEkoYykpLnNwbGl0
KCIgIik7Zm9yKGs9MDtrPGMubGVuZ3RoO2srKyl7bD1BLmV4ZWMoY1trXSl8fFtdLG09bFsxXSxu
PShsWzJdfHwiIikuc3BsaXQoIi4iKS5zb3J0KCkscz1mLmV2ZW50LnNwZWNpYWxbbV18fHt9LG09
KGc/cy5kZWxlZ2F0ZVR5cGU6cy5iaW5kVHlwZSl8fG0scz1mLmV2ZW50LnNwZWNpYWxbbV18fHt9
LG89Zi5leHRlbmQoe3R5cGU6bSxvcmlnVHlwZTpsWzFdLGRhdGE6ZSxoYW5kbGVyOmQsZ3VpZDpk
Lmd1aWQsc2VsZWN0b3I6ZyxxdWljazpnJiZHKGcpLG5hbWVzcGFjZTpuLmpvaW4oIi4iKX0scCks
cj1qW21dO2lmKCFyKXtyPWpbbV09W10sci5kZWxlZ2F0ZUNvdW50PTA7aWYoIXMuc2V0dXB8fHMu
c2V0dXAuY2FsbChhLGUsbixpKT09PSExKWEuYWRkRXZlbnRMaXN0ZW5lcj9hLmFkZEV2ZW50TGlz
dGVuZXIobSxpLCExKTphLmF0dGFjaEV2ZW50JiZhLmF0dGFjaEV2ZW50KCJvbiIrbSxpKX1zLmFk
ZCYmKHMuYWRkLmNhbGwoYSxvKSxvLmhhbmRsZXIuZ3VpZHx8KG8uaGFuZGxlci5ndWlkPWQuZ3Vp
ZCkpLGc/ci5zcGxpY2Uoci5kZWxlZ2F0ZUNvdW50KyssMCxvKTpyLnB1c2gobyksZi5ldmVudC5n
bG9iYWxbbV09ITB9YT1udWxsfX0sZ2xvYmFsOnt9LHJlbW92ZTpmdW5jdGlvbihhLGIsYyxkLGUp
e3ZhciBnPWYuaGFzRGF0YShhKSYmZi5fZGF0YShhKSxoLGksaixrLGwsbSxuLG8scCxxLHIscztp
ZighIWcmJiEhKG89Zy5ldmVudHMpKXtiPWYudHJpbShJKGJ8fCIiKSkuc3BsaXQoIiAiKTtmb3Io
aD0wO2g8Yi5sZW5ndGg7aCsrKXtpPUEuZXhlYyhiW2hdKXx8W10saj1rPWlbMV0sbD1pWzJdO2lm
KCFqKXtmb3IoaiBpbiBvKWYuZXZlbnQucmVtb3ZlKGEsaitiW2hdLGMsZCwhMCk7Y29udGludWV9
cD1mLmV2ZW50LnNwZWNpYWxbal18fHt9LGo9KGQ/cC5kZWxlZ2F0ZVR5cGU6cC5iaW5kVHlwZSl8
fGoscj1vW2pdfHxbXSxtPXIubGVuZ3RoLGw9bD9uZXcgUmVnRXhwKCIoXnxcXC4pIitsLnNwbGl0
KCIuIikuc29ydCgpLmpvaW4oIlxcLig/Oi4qXFwuKT8iKSsiKFxcLnwkKSIpOm51bGw7Zm9yKG49
MDtuPHIubGVuZ3RoO24rKylzPXJbbl0sKGV8fGs9PT1zLm9yaWdUeXBlKSYmKCFjfHxjLmd1aWQ9
PT1zLmd1aWQpJiYoIWx8fGwudGVzdChzLm5hbWVzcGFjZSkpJiYoIWR8fGQ9PT1zLnNlbGVjdG9y
fHxkPT09IioqIiYmcy5zZWxlY3RvcikmJihyLnNwbGljZShuLS0sMSkscy5zZWxlY3RvciYmci5k
ZWxlZ2F0ZUNvdW50LS0scC5yZW1vdmUmJnAucmVtb3ZlLmNhbGwoYSxzKSk7ci5sZW5ndGg9PT0w
JiZtIT09ci5sZW5ndGgmJigoIXAudGVhcmRvd258fHAudGVhcmRvd24uY2FsbChhLGwpPT09ITEp
JiZmLnJlbW92ZUV2ZW50KGEsaixnLmhhbmRsZSksZGVsZXRlIG9bal0pfWYuaXNFbXB0eU9iamVj
dChvKSYmKHE9Zy5oYW5kbGUscSYmKHEuZWxlbT1udWxsKSxmLnJlbW92ZURhdGEoYSxbImV2ZW50
cyIsImhhbmRsZSJdLCEwKSl9fSxjdXN0b21FdmVudDp7Z2V0RGF0YTohMCxzZXREYXRhOiEwLGNo
YW5nZURhdGE6ITB9LHRyaWdnZXI6ZnVuY3Rpb24oYyxkLGUsZyl7aWYoIWV8fGUubm9kZVR5cGUh
PT0zJiZlLm5vZGVUeXBlIT09OCl7dmFyIGg9Yy50eXBlfHxjLGk9W10saixrLGwsbSxuLG8scCxx
LHIscztpZihFLnRlc3QoaCtmLmV2ZW50LnRyaWdnZXJlZCkpcmV0dXJuO2guaW5kZXhPZigiISIp
Pj0wJiYoaD1oLnNsaWNlKDAsLTEpLGs9ITApLGguaW5kZXhPZigiLiIpPj0wJiYoaT1oLnNwbGl0
KCIuIiksaD1pLnNoaWZ0KCksaS5zb3J0KCkpO2lmKCghZXx8Zi5ldmVudC5jdXN0b21FdmVudFto
XSkmJiFmLmV2ZW50Lmdsb2JhbFtoXSlyZXR1cm47Yz10eXBlb2YgYz09Im9iamVjdCI/Y1tmLmV4
cGFuZG9dP2M6bmV3IGYuRXZlbnQoaCxjKTpuZXcgZi5FdmVudChoKSxjLnR5cGU9aCxjLmlzVHJp
Z2dlcj0hMCxjLmV4Y2x1c2l2ZT1rLGMubmFtZXNwYWNlPWkuam9pbigiLiIpLGMubmFtZXNwYWNl
X3JlPWMubmFtZXNwYWNlP25ldyBSZWdFeHAoIihefFxcLikiK2kuam9pbigiXFwuKD86LipcXC4p
PyIpKyIoXFwufCQpIik6bnVsbCxvPWguaW5kZXhPZigiOiIpPDA/Im9uIitoOiIiO2lmKCFlKXtq
PWYuY2FjaGU7Zm9yKGwgaW4gailqW2xdLmV2ZW50cyYmaltsXS5ldmVudHNbaF0mJmYuZXZlbnQu
dHJpZ2dlcihjLGQsaltsXS5oYW5kbGUuZWxlbSwhMCk7cmV0dXJufWMucmVzdWx0PWIsYy50YXJn
ZXR8fChjLnRhcmdldD1lKSxkPWQhPW51bGw/Zi5tYWtlQXJyYXkoZCk6W10sZC51bnNoaWZ0KGMp
LHA9Zi5ldmVudC5zcGVjaWFsW2hdfHx7fTtpZihwLnRyaWdnZXImJnAudHJpZ2dlci5hcHBseShl
LGQpPT09ITEpcmV0dXJuO3I9W1tlLHAuYmluZFR5cGV8fGhdXTtpZighZyYmIXAubm9CdWJibGUm
JiFmLmlzV2luZG93KGUpKXtzPXAuZGVsZWdhdGVUeXBlfHxoLG09RS50ZXN0KHMraCk/ZTplLnBh
cmVudE5vZGUsbj1udWxsO2Zvcig7bTttPW0ucGFyZW50Tm9kZSlyLnB1c2goW20sc10pLG49bTtu
JiZuPT09ZS5vd25lckRvY3VtZW50JiZyLnB1c2goW24uZGVmYXVsdFZpZXd8fG4ucGFyZW50V2lu
ZG93fHxhLHNdKX1mb3IobD0wO2w8ci5sZW5ndGgmJiFjLmlzUHJvcGFnYXRpb25TdG9wcGVkKCk7
bCsrKW09cltsXVswXSxjLnR5cGU9cltsXVsxXSxxPShmLl9kYXRhKG0sImV2ZW50cyIpfHx7fSlb
Yy50eXBlXSYmZi5fZGF0YShtLCJoYW5kbGUiKSxxJiZxLmFwcGx5KG0sZCkscT1vJiZtW29dLHEm
JmYuYWNjZXB0RGF0YShtKSYmcS5hcHBseShtLGQpPT09ITEmJmMucHJldmVudERlZmF1bHQoKTtj
LnR5cGU9aCwhZyYmIWMuaXNEZWZhdWx0UHJldmVudGVkKCkmJighcC5fZGVmYXVsdHx8cC5fZGVm
YXVsdC5hcHBseShlLm93bmVyRG9jdW1lbnQsZCk9PT0hMSkmJihoIT09ImNsaWNrInx8IWYubm9k
ZU5hbWUoZSwiYSIpKSYmZi5hY2NlcHREYXRhKGUpJiZvJiZlW2hdJiYoaCE9PSJmb2N1cyImJmgh
PT0iYmx1ciJ8fGMudGFyZ2V0Lm9mZnNldFdpZHRoIT09MCkmJiFmLmlzV2luZG93KGUpJiYobj1l
W29dLG4mJihlW29dPW51bGwpLGYuZXZlbnQudHJpZ2dlcmVkPWgsZVtoXSgpLGYuZXZlbnQudHJp
Z2dlcmVkPWIsbiYmKGVbb109bikpO3JldHVybiBjLnJlc3VsdH19LGRpc3BhdGNoOmZ1bmN0aW9u
KGMpe2M9Zi5ldmVudC5maXgoY3x8YS5ldmVudCk7dmFyIGQ9KGYuX2RhdGEodGhpcywiZXZlbnRz
Iil8fHt9KVtjLnR5cGVdfHxbXSxlPWQuZGVsZWdhdGVDb3VudCxnPVtdLnNsaWNlLmNhbGwoYXJn
dW1lbnRzLDApLGg9IWMuZXhjbHVzaXZlJiYhYy5uYW1lc3BhY2UsaT1mLmV2ZW50LnNwZWNpYWxb
Yy50eXBlXXx8e30saj1bXSxrLGwsbSxuLG8scCxxLHIscyx0LHU7Z1swXT1jLGMuZGVsZWdhdGVU
YXJnZXQ9dGhpcztpZighaS5wcmVEaXNwYXRjaHx8aS5wcmVEaXNwYXRjaC5jYWxsKHRoaXMsYykh
PT0hMSl7aWYoZSYmKCFjLmJ1dHRvbnx8Yy50eXBlIT09ImNsaWNrIikpe249Zih0aGlzKSxuLmNv
bnRleHQ9dGhpcy5vd25lckRvY3VtZW50fHx0aGlzO2ZvcihtPWMudGFyZ2V0O20hPXRoaXM7bT1t
LnBhcmVudE5vZGV8fHRoaXMpaWYobS5kaXNhYmxlZCE9PSEwKXtwPXt9LHI9W10sblswXT1tO2Zv
cihrPTA7azxlO2srKylzPWRba10sdD1zLnNlbGVjdG9yLHBbdF09PT1iJiYocFt0XT1zLnF1aWNr
P0gobSxzLnF1aWNrKTpuLmlzKHQpKSxwW3RdJiZyLnB1c2gocyk7ci5sZW5ndGgmJmoucHVzaCh7
ZWxlbTptLG1hdGNoZXM6cn0pfX1kLmxlbmd0aD5lJiZqLnB1c2goe2VsZW06dGhpcyxtYXRjaGVz
OmQuc2xpY2UoZSl9KTtmb3Ioaz0wO2s8ai5sZW5ndGgmJiFjLmlzUHJvcGFnYXRpb25TdG9wcGVk
KCk7aysrKXtxPWpba10sYy5jdXJyZW50VGFyZ2V0PXEuZWxlbTtmb3IobD0wO2w8cS5tYXRjaGVz
Lmxlbmd0aCYmIWMuaXNJbW1lZGlhdGVQcm9wYWdhdGlvblN0b3BwZWQoKTtsKyspe3M9cS5tYXRj
aGVzW2xdO2lmKGh8fCFjLm5hbWVzcGFjZSYmIXMubmFtZXNwYWNlfHxjLm5hbWVzcGFjZV9yZSYm
Yy5uYW1lc3BhY2VfcmUudGVzdChzLm5hbWVzcGFjZSkpYy5kYXRhPXMuZGF0YSxjLmhhbmRsZU9i
aj1zLG89KChmLmV2ZW50LnNwZWNpYWxbcy5vcmlnVHlwZV18fHt9KS5oYW5kbGV8fHMuaGFuZGxl
cikuYXBwbHkocS5lbGVtLGcpLG8hPT1iJiYoYy5yZXN1bHQ9byxvPT09ITEmJihjLnByZXZlbnRE
ZWZhdWx0KCksYy5zdG9wUHJvcGFnYXRpb24oKSkpfX1pLnBvc3REaXNwYXRjaCYmaS5wb3N0RGlz
cGF0Y2guY2FsbCh0aGlzLGMpO3JldHVybiBjLnJlc3VsdH19LHByb3BzOiJhdHRyQ2hhbmdlIGF0
dHJOYW1lIHJlbGF0ZWROb2RlIHNyY0VsZW1lbnQgYWx0S2V5IGJ1YmJsZXMgY2FuY2VsYWJsZSBj
dHJsS2V5IGN1cnJlbnRUYXJnZXQgZXZlbnRQaGFzZSBtZXRhS2V5IHJlbGF0ZWRUYXJnZXQgc2hp
ZnRLZXkgdGFyZ2V0IHRpbWVTdGFtcCB2aWV3IHdoaWNoIi5zcGxpdCgiICIpLGZpeEhvb2tzOnt9
LGtleUhvb2tzOntwcm9wczoiY2hhciBjaGFyQ29kZSBrZXkga2V5Q29kZSIuc3BsaXQoIiAiKSxm
aWx0ZXI6ZnVuY3Rpb24oYSxiKXthLndoaWNoPT1udWxsJiYoYS53aGljaD1iLmNoYXJDb2RlIT1u
dWxsP2IuY2hhckNvZGU6Yi5rZXlDb2RlKTtyZXR1cm4gYX19LG1vdXNlSG9va3M6e3Byb3BzOiJi
dXR0b24gYnV0dG9ucyBjbGllbnRYIGNsaWVudFkgZnJvbUVsZW1lbnQgb2Zmc2V0WCBvZmZzZXRZ
IHBhZ2VYIHBhZ2VZIHNjcmVlblggc2NyZWVuWSB0b0VsZW1lbnQiLnNwbGl0KCIgIiksZmlsdGVy
OmZ1bmN0aW9uKGEsZCl7dmFyIGUsZixnLGg9ZC5idXR0b24saT1kLmZyb21FbGVtZW50O2EucGFn
ZVg9PW51bGwmJmQuY2xpZW50WCE9bnVsbCYmKGU9YS50YXJnZXQub3duZXJEb2N1bWVudHx8Yyxm
PWUuZG9jdW1lbnRFbGVtZW50LGc9ZS5ib2R5LGEucGFnZVg9ZC5jbGllbnRYKyhmJiZmLnNjcm9s
bExlZnR8fGcmJmcuc2Nyb2xsTGVmdHx8MCktKGYmJmYuY2xpZW50TGVmdHx8ZyYmZy5jbGllbnRM
ZWZ0fHwwKSxhLnBhZ2VZPWQuY2xpZW50WSsoZiYmZi5zY3JvbGxUb3B8fGcmJmcuc2Nyb2xsVG9w
fHwwKS0oZiYmZi5jbGllbnRUb3B8fGcmJmcuY2xpZW50VG9wfHwwKSksIWEucmVsYXRlZFRhcmdl
dCYmaSYmKGEucmVsYXRlZFRhcmdldD1pPT09YS50YXJnZXQ/ZC50b0VsZW1lbnQ6aSksIWEud2hp
Y2gmJmghPT1iJiYoYS53aGljaD1oJjE/MTpoJjI/MzpoJjQ/MjowKTtyZXR1cm4gYX19LGZpeDpm
dW5jdGlvbihhKXtpZihhW2YuZXhwYW5kb10pcmV0dXJuIGE7dmFyIGQsZSxnPWEsaD1mLmV2ZW50
LmZpeEhvb2tzW2EudHlwZV18fHt9LGk9aC5wcm9wcz90aGlzLnByb3BzLmNvbmNhdChoLnByb3Bz
KTp0aGlzLnByb3BzO2E9Zi5FdmVudChnKTtmb3IoZD1pLmxlbmd0aDtkOyllPWlbLS1kXSxhW2Vd
PWdbZV07YS50YXJnZXR8fChhLnRhcmdldD1nLnNyY0VsZW1lbnR8fGMpLGEudGFyZ2V0Lm5vZGVU
eXBlPT09MyYmKGEudGFyZ2V0PWEudGFyZ2V0LnBhcmVudE5vZGUpLGEubWV0YUtleT09PWImJihh
Lm1ldGFLZXk9YS5jdHJsS2V5KTtyZXR1cm4gaC5maWx0ZXI/aC5maWx0ZXIoYSxnKTphfSxzcGVj
aWFsOntyZWFkeTp7c2V0dXA6Zi5iaW5kUmVhZHl9LGxvYWQ6e25vQnViYmxlOiEwfSxmb2N1czp7
ZGVsZWdhdGVUeXBlOiJmb2N1c2luIn0sYmx1cjp7ZGVsZWdhdGVUeXBlOiJmb2N1c291dCJ9LGJl
Zm9yZXVubG9hZDp7c2V0dXA6ZnVuY3Rpb24oYSxiLGMpe2YuaXNXaW5kb3codGhpcykmJih0aGlz
Lm9uYmVmb3JldW5sb2FkPWMpfSx0ZWFyZG93bjpmdW5jdGlvbihhLGIpe3RoaXMub25iZWZvcmV1
bmxvYWQ9PT1iJiYodGhpcy5vbmJlZm9yZXVubG9hZD1udWxsKX19fSxzaW11bGF0ZTpmdW5jdGlv
bihhLGIsYyxkKXt2YXIgZT1mLmV4dGVuZChuZXcgZi5FdmVudCxjLHt0eXBlOmEsaXNTaW11bGF0
ZWQ6ITAsb3JpZ2luYWxFdmVudDp7fX0pO2Q/Zi5ldmVudC50cmlnZ2VyKGUsbnVsbCxiKTpmLmV2
ZW50LmRpc3BhdGNoLmNhbGwoYixlKSxlLmlzRGVmYXVsdFByZXZlbnRlZCgpJiZjLnByZXZlbnRE
ZWZhdWx0KCl9fSxmLmV2ZW50LmhhbmRsZT1mLmV2ZW50LmRpc3BhdGNoLGYucmVtb3ZlRXZlbnQ9
Yy5yZW1vdmVFdmVudExpc3RlbmVyP2Z1bmN0aW9uKGEsYixjKXthLnJlbW92ZUV2ZW50TGlzdGVu
ZXImJmEucmVtb3ZlRXZlbnRMaXN0ZW5lcihiLGMsITEpfTpmdW5jdGlvbihhLGIsYyl7YS5kZXRh
Y2hFdmVudCYmYS5kZXRhY2hFdmVudCgib24iK2IsYyl9LGYuRXZlbnQ9ZnVuY3Rpb24oYSxiKXtp
ZighKHRoaXMgaW5zdGFuY2VvZiBmLkV2ZW50KSlyZXR1cm4gbmV3IGYuRXZlbnQoYSxiKTthJiZh
LnR5cGU/KHRoaXMub3JpZ2luYWxFdmVudD1hLHRoaXMudHlwZT1hLnR5cGUsdGhpcy5pc0RlZmF1
bHRQcmV2ZW50ZWQ9YS5kZWZhdWx0UHJldmVudGVkfHxhLnJldHVyblZhbHVlPT09ITF8fGEuZ2V0
UHJldmVudERlZmF1bHQmJmEuZ2V0UHJldmVudERlZmF1bHQoKT9LOkopOnRoaXMudHlwZT1hLGIm
JmYuZXh0ZW5kKHRoaXMsYiksdGhpcy50aW1lU3RhbXA9YSYmYS50aW1lU3RhbXB8fGYubm93KCks
dGhpc1tmLmV4cGFuZG9dPSEwfSxmLkV2ZW50LnByb3RvdHlwZT17cHJldmVudERlZmF1bHQ6ZnVu
Y3Rpb24oKXt0aGlzLmlzRGVmYXVsdFByZXZlbnRlZD1LO3ZhciBhPXRoaXMub3JpZ2luYWxFdmVu
dDshYXx8KGEucHJldmVudERlZmF1bHQ/YS5wcmV2ZW50RGVmYXVsdCgpOmEucmV0dXJuVmFsdWU9
ITEpfSxzdG9wUHJvcGFnYXRpb246ZnVuY3Rpb24oKXt0aGlzLmlzUHJvcGFnYXRpb25TdG9wcGVk
PUs7dmFyIGE9dGhpcy5vcmlnaW5hbEV2ZW50OyFhfHwoYS5zdG9wUHJvcGFnYXRpb24mJmEuc3Rv
cFByb3BhZ2F0aW9uKCksYS5jYW5jZWxCdWJibGU9ITApfSxzdG9wSW1tZWRpYXRlUHJvcGFnYXRp
b246ZnVuY3Rpb24oKXt0aGlzLmlzSW1tZWRpYXRlUHJvcGFnYXRpb25TdG9wcGVkPUssdGhpcy5z
dG9wUHJvcGFnYXRpb24oKX0saXNEZWZhdWx0UHJldmVudGVkOkosaXNQcm9wYWdhdGlvblN0b3Bw
ZWQ6Sixpc0ltbWVkaWF0ZVByb3BhZ2F0aW9uU3RvcHBlZDpKfSxmLmVhY2goe21vdXNlZW50ZXI6
Im1vdXNlb3ZlciIsbW91c2VsZWF2ZToibW91c2VvdXQifSxmdW5jdGlvbihhLGIpe2YuZXZlbnQu
c3BlY2lhbFthXT17ZGVsZWdhdGVUeXBlOmIsYmluZFR5cGU6YixoYW5kbGU6ZnVuY3Rpb24oYSl7
dmFyIGM9dGhpcyxkPWEucmVsYXRlZFRhcmdldCxlPWEuaGFuZGxlT2JqLGc9ZS5zZWxlY3Rvcixo
O2lmKCFkfHxkIT09YyYmIWYuY29udGFpbnMoYyxkKSlhLnR5cGU9ZS5vcmlnVHlwZSxoPWUuaGFu
ZGxlci5hcHBseSh0aGlzLGFyZ3VtZW50cyksYS50eXBlPWI7cmV0dXJuIGh9fX0pLGYuc3VwcG9y
dC5zdWJtaXRCdWJibGVzfHwoZi5ldmVudC5zcGVjaWFsLnN1Ym1pdD17c2V0dXA6ZnVuY3Rpb24o
KXtpZihmLm5vZGVOYW1lKHRoaXMsImZvcm0iKSlyZXR1cm4hMTtmLmV2ZW50LmFkZCh0aGlzLCJj
bGljay5fc3VibWl0IGtleXByZXNzLl9zdWJtaXQiLGZ1bmN0aW9uKGEpe3ZhciBjPWEudGFyZ2V0
LGQ9Zi5ub2RlTmFtZShjLCJpbnB1dCIpfHxmLm5vZGVOYW1lKGMsImJ1dHRvbiIpP2MuZm9ybTpi
O2QmJiFkLl9zdWJtaXRfYXR0YWNoZWQmJihmLmV2ZW50LmFkZChkLCJzdWJtaXQuX3N1Ym1pdCIs
ZnVuY3Rpb24oYSl7YS5fc3VibWl0X2J1YmJsZT0hMH0pLGQuX3N1Ym1pdF9hdHRhY2hlZD0hMCl9
KX0scG9zdERpc3BhdGNoOmZ1bmN0aW9uKGEpe2EuX3N1Ym1pdF9idWJibGUmJihkZWxldGUgYS5f
c3VibWl0X2J1YmJsZSx0aGlzLnBhcmVudE5vZGUmJiFhLmlzVHJpZ2dlciYmZi5ldmVudC5zaW11
bGF0ZSgic3VibWl0Iix0aGlzLnBhcmVudE5vZGUsYSwhMCkpfSx0ZWFyZG93bjpmdW5jdGlvbigp
e2lmKGYubm9kZU5hbWUodGhpcywiZm9ybSIpKXJldHVybiExO2YuZXZlbnQucmVtb3ZlKHRoaXMs
Ii5fc3VibWl0Iil9fSksZi5zdXBwb3J0LmNoYW5nZUJ1YmJsZXN8fChmLmV2ZW50LnNwZWNpYWwu
Y2hhbmdlPXtzZXR1cDpmdW5jdGlvbigpe2lmKHoudGVzdCh0aGlzLm5vZGVOYW1lKSl7aWYodGhp
cy50eXBlPT09ImNoZWNrYm94Inx8dGhpcy50eXBlPT09InJhZGlvIilmLmV2ZW50LmFkZCh0aGlz
LCJwcm9wZXJ0eWNoYW5nZS5fY2hhbmdlIixmdW5jdGlvbihhKXthLm9yaWdpbmFsRXZlbnQucHJv
cGVydHlOYW1lPT09ImNoZWNrZWQiJiYodGhpcy5fanVzdF9jaGFuZ2VkPSEwKX0pLGYuZXZlbnQu
YWRkKHRoaXMsImNsaWNrLl9jaGFuZ2UiLGZ1bmN0aW9uKGEpe3RoaXMuX2p1c3RfY2hhbmdlZCYm
IWEuaXNUcmlnZ2VyJiYodGhpcy5fanVzdF9jaGFuZ2VkPSExLGYuZXZlbnQuc2ltdWxhdGUoImNo
YW5nZSIsdGhpcyxhLCEwKSl9KTtyZXR1cm4hMX1mLmV2ZW50LmFkZCh0aGlzLCJiZWZvcmVhY3Rp
dmF0ZS5fY2hhbmdlIixmdW5jdGlvbihhKXt2YXIgYj1hLnRhcmdldDt6LnRlc3QoYi5ub2RlTmFt
ZSkmJiFiLl9jaGFuZ2VfYXR0YWNoZWQmJihmLmV2ZW50LmFkZChiLCJjaGFuZ2UuX2NoYW5nZSIs
ZnVuY3Rpb24oYSl7dGhpcy5wYXJlbnROb2RlJiYhYS5pc1NpbXVsYXRlZCYmIWEuaXNUcmlnZ2Vy
JiZmLmV2ZW50LnNpbXVsYXRlKCJjaGFuZ2UiLHRoaXMucGFyZW50Tm9kZSxhLCEwKX0pLGIuX2No
YW5nZV9hdHRhY2hlZD0hMCl9KX0saGFuZGxlOmZ1bmN0aW9uKGEpe3ZhciBiPWEudGFyZ2V0O2lm
KHRoaXMhPT1ifHxhLmlzU2ltdWxhdGVkfHxhLmlzVHJpZ2dlcnx8Yi50eXBlIT09InJhZGlvIiYm
Yi50eXBlIT09ImNoZWNrYm94IilyZXR1cm4gYS5oYW5kbGVPYmouaGFuZGxlci5hcHBseSh0aGlz
LGFyZ3VtZW50cyl9LHRlYXJkb3duOmZ1bmN0aW9uKCl7Zi5ldmVudC5yZW1vdmUodGhpcywiLl9j
aGFuZ2UiKTtyZXR1cm4gei50ZXN0KHRoaXMubm9kZU5hbWUpfX0pLGYuc3VwcG9ydC5mb2N1c2lu
QnViYmxlc3x8Zi5lYWNoKHtmb2N1czoiZm9jdXNpbiIsYmx1cjoiZm9jdXNvdXQifSxmdW5jdGlv
bihhLGIpe3ZhciBkPTAsZT1mdW5jdGlvbihhKXtmLmV2ZW50LnNpbXVsYXRlKGIsYS50YXJnZXQs
Zi5ldmVudC5maXgoYSksITApfTtmLmV2ZW50LnNwZWNpYWxbYl09e3NldHVwOmZ1bmN0aW9uKCl7
ZCsrPT09MCYmYy5hZGRFdmVudExpc3RlbmVyKGEsZSwhMCl9LHRlYXJkb3duOmZ1bmN0aW9uKCl7
LS1kPT09MCYmYy5yZW1vdmVFdmVudExpc3RlbmVyKGEsZSwhMCl9fX0pLGYuZm4uZXh0ZW5kKHtv
bjpmdW5jdGlvbihhLGMsZCxlLGcpe3ZhciBoLGk7aWYodHlwZW9mIGE9PSJvYmplY3QiKXt0eXBl
b2YgYyE9InN0cmluZyImJihkPWR8fGMsYz1iKTtmb3IoaSBpbiBhKXRoaXMub24oaSxjLGQsYVtp
XSxnKTtyZXR1cm4gdGhpc31kPT1udWxsJiZlPT1udWxsPyhlPWMsZD1jPWIpOmU9PW51bGwmJih0
eXBlb2YgYz09InN0cmluZyI/KGU9ZCxkPWIpOihlPWQsZD1jLGM9YikpO2lmKGU9PT0hMSllPUo7
ZWxzZSBpZighZSlyZXR1cm4gdGhpcztnPT09MSYmKGg9ZSxlPWZ1bmN0aW9uKGEpe2YoKS5vZmYo
YSk7cmV0dXJuIGguYXBwbHkodGhpcyxhcmd1bWVudHMpfSxlLmd1aWQ9aC5ndWlkfHwoaC5ndWlk
PWYuZ3VpZCsrKSk7cmV0dXJuIHRoaXMuZWFjaChmdW5jdGlvbigpe2YuZXZlbnQuYWRkKHRoaXMs
YSxlLGQsYyl9KX0sb25lOmZ1bmN0aW9uKGEsYixjLGQpe3JldHVybiB0aGlzLm9uKGEsYixjLGQs
MSl9LG9mZjpmdW5jdGlvbihhLGMsZCl7aWYoYSYmYS5wcmV2ZW50RGVmYXVsdCYmYS5oYW5kbGVP
Ymope3ZhciBlPWEuaGFuZGxlT2JqO2YoYS5kZWxlZ2F0ZVRhcmdldCkub2ZmKGUubmFtZXNwYWNl
P2Uub3JpZ1R5cGUrIi4iK2UubmFtZXNwYWNlOmUub3JpZ1R5cGUsZS5zZWxlY3RvcixlLmhhbmRs
ZXIpO3JldHVybiB0aGlzfWlmKHR5cGVvZiBhPT0ib2JqZWN0Iil7Zm9yKHZhciBnIGluIGEpdGhp
cy5vZmYoZyxjLGFbZ10pO3JldHVybiB0aGlzfWlmKGM9PT0hMXx8dHlwZW9mIGM9PSJmdW5jdGlv
biIpZD1jLGM9YjtkPT09ITEmJihkPUopO3JldHVybiB0aGlzLmVhY2goZnVuY3Rpb24oKXtmLmV2
ZW50LnJlbW92ZSh0aGlzLGEsZCxjKX0pfSxiaW5kOmZ1bmN0aW9uKGEsYixjKXtyZXR1cm4gdGhp
cy5vbihhLG51bGwsYixjKX0sdW5iaW5kOmZ1bmN0aW9uKGEsYil7cmV0dXJuIHRoaXMub2ZmKGEs
bnVsbCxiKX0sbGl2ZTpmdW5jdGlvbihhLGIsYyl7Zih0aGlzLmNvbnRleHQpLm9uKGEsdGhpcy5z
ZWxlY3RvcixiLGMpO3JldHVybiB0aGlzfSxkaWU6ZnVuY3Rpb24oYSxiKXtmKHRoaXMuY29udGV4
dCkub2ZmKGEsdGhpcy5zZWxlY3Rvcnx8IioqIixiKTtyZXR1cm4gdGhpc30sZGVsZWdhdGU6ZnVu
Y3Rpb24oYSxiLGMsZCl7cmV0dXJuIHRoaXMub24oYixhLGMsZCl9LHVuZGVsZWdhdGU6ZnVuY3Rp
b24oYSxiLGMpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPT0xP3RoaXMub2ZmKGEsIioqIik6dGhp
cy5vZmYoYixhLGMpfSx0cmlnZ2VyOmZ1bmN0aW9uKGEsYil7cmV0dXJuIHRoaXMuZWFjaChmdW5j
dGlvbigpe2YuZXZlbnQudHJpZ2dlcihhLGIsdGhpcyl9KX0sdHJpZ2dlckhhbmRsZXI6ZnVuY3Rp
b24oYSxiKXtpZih0aGlzWzBdKXJldHVybiBmLmV2ZW50LnRyaWdnZXIoYSxiLHRoaXNbMF0sITAp
fSx0b2dnbGU6ZnVuY3Rpb24oYSl7dmFyIGI9YXJndW1lbnRzLGM9YS5ndWlkfHxmLmd1aWQrKyxk
PTAsZT1mdW5jdGlvbihjKXt2YXIgZT0oZi5fZGF0YSh0aGlzLCJsYXN0VG9nZ2xlIithLmd1aWQp
fHwwKSVkO2YuX2RhdGEodGhpcywibGFzdFRvZ2dsZSIrYS5ndWlkLGUrMSksYy5wcmV2ZW50RGVm
YXVsdCgpO3JldHVybiBiW2VdLmFwcGx5KHRoaXMsYXJndW1lbnRzKXx8ITF9O2UuZ3VpZD1jO3do
aWxlKGQ8Yi5sZW5ndGgpYltkKytdLmd1aWQ9YztyZXR1cm4gdGhpcy5jbGljayhlKX0saG92ZXI6
ZnVuY3Rpb24oYSxiKXtyZXR1cm4gdGhpcy5tb3VzZWVudGVyKGEpLm1vdXNlbGVhdmUoYnx8YSl9
fSksZi5lYWNoKCJibHVyIGZvY3VzIGZvY3VzaW4gZm9jdXNvdXQgbG9hZCByZXNpemUgc2Nyb2xs
IHVubG9hZCBjbGljayBkYmxjbGljayBtb3VzZWRvd24gbW91c2V1cCBtb3VzZW1vdmUgbW91c2Vv
dmVyIG1vdXNlb3V0IG1vdXNlZW50ZXIgbW91c2VsZWF2ZSBjaGFuZ2Ugc2VsZWN0IHN1Ym1pdCBr
ZXlkb3duIGtleXByZXNzIGtleXVwIGVycm9yIGNvbnRleHRtZW51Ii5zcGxpdCgiICIpLGZ1bmN0
aW9uKGEsYil7Zi5mbltiXT1mdW5jdGlvbihhLGMpe2M9PW51bGwmJihjPWEsYT1udWxsKTtyZXR1
cm4gYXJndW1lbnRzLmxlbmd0aD4wP3RoaXMub24oYixudWxsLGEsYyk6dGhpcy50cmlnZ2VyKGIp
fSxmLmF0dHJGbiYmKGYuYXR0ckZuW2JdPSEwKSxDLnRlc3QoYikmJihmLmV2ZW50LmZpeEhvb2tz
W2JdPWYuZXZlbnQua2V5SG9va3MpLEQudGVzdChiKSYmKGYuZXZlbnQuZml4SG9va3NbYl09Zi5l
dmVudC5tb3VzZUhvb2tzKX0pLGZ1bmN0aW9uKCl7ZnVuY3Rpb24geChhLGIsYyxlLGYsZyl7Zm9y
KHZhciBoPTAsaT1lLmxlbmd0aDtoPGk7aCsrKXt2YXIgaj1lW2hdO2lmKGope3ZhciBrPSExO2o9
althXTt3aGlsZShqKXtpZihqW2RdPT09Yyl7az1lW2ouc2l6c2V0XTticmVha31pZihqLm5vZGVU
eXBlPT09MSl7Z3x8KGpbZF09YyxqLnNpenNldD1oKTtpZih0eXBlb2YgYiE9InN0cmluZyIpe2lm
KGo9PT1iKXtrPSEwO2JyZWFrfX1lbHNlIGlmKG0uZmlsdGVyKGIsW2pdKS5sZW5ndGg+MCl7az1q
O2JyZWFrfX1qPWpbYV19ZVtoXT1rfX19ZnVuY3Rpb24gdyhhLGIsYyxlLGYsZyl7Zm9yKHZhciBo
PTAsaT1lLmxlbmd0aDtoPGk7aCsrKXt2YXIgaj1lW2hdO2lmKGope3ZhciBrPSExO2o9althXTt3
aGlsZShqKXtpZihqW2RdPT09Yyl7az1lW2ouc2l6c2V0XTticmVha31qLm5vZGVUeXBlPT09MSYm
IWcmJihqW2RdPWMsai5zaXpzZXQ9aCk7aWYoai5ub2RlTmFtZS50b0xvd2VyQ2FzZSgpPT09Yil7
az1qO2JyZWFrfWo9althXX1lW2hdPWt9fX12YXIgYT0vKCg/OlwoKD86XChbXigpXStcKXxbXigp
XSspK1wpfFxbKD86XFtbXlxbXF1dKlxdfFsnIl1bXiciXSpbJyJdfFteXFtcXSciXSspK1xdfFxc
LnxbXiA+K34sKFxbXFxdKykrfFs+K35dKShccyosXHMqKT8oKD86LnxccnxcbikqKS9nLGQ9InNp
emNhY2hlIisoTWF0aC5yYW5kb20oKSsiIikucmVwbGFjZSgiLiIsIiIpLGU9MCxnPU9iamVjdC5w
cm90b3R5cGUudG9TdHJpbmcsaD0hMSxpPSEwLGo9L1xcL2csaz0vXHJcbi9nLGw9L1xXLztbMCww
XS5zb3J0KGZ1bmN0aW9uKCl7aT0hMTtyZXR1cm4gMH0pO3ZhciBtPWZ1bmN0aW9uKGIsZCxlLGYp
e2U9ZXx8W10sZD1kfHxjO3ZhciBoPWQ7aWYoZC5ub2RlVHlwZSE9PTEmJmQubm9kZVR5cGUhPT05
KXJldHVybltdO2lmKCFifHx0eXBlb2YgYiE9InN0cmluZyIpcmV0dXJuIGU7dmFyIGksaixrLGws
bixxLHIsdCx1PSEwLHY9bS5pc1hNTChkKSx3PVtdLHg9Yjtkb3thLmV4ZWMoIiIpLGk9YS5leGVj
KHgpO2lmKGkpe3g9aVszXSx3LnB1c2goaVsxXSk7aWYoaVsyXSl7bD1pWzNdO2JyZWFrfX19d2hp
bGUoaSk7aWYody5sZW5ndGg+MSYmcC5leGVjKGIpKWlmKHcubGVuZ3RoPT09MiYmby5yZWxhdGl2
ZVt3WzBdXSlqPXkod1swXSt3WzFdLGQsZik7ZWxzZXtqPW8ucmVsYXRpdmVbd1swXV0/W2RdOm0o
dy5zaGlmdCgpLGQpO3doaWxlKHcubGVuZ3RoKWI9dy5zaGlmdCgpLG8ucmVsYXRpdmVbYl0mJihi
Kz13LnNoaWZ0KCkpLGo9eShiLGosZil9ZWxzZXshZiYmdy5sZW5ndGg+MSYmZC5ub2RlVHlwZT09
PTkmJiF2JiZvLm1hdGNoLklELnRlc3Qod1swXSkmJiFvLm1hdGNoLklELnRlc3Qod1t3Lmxlbmd0
aC0xXSkmJihuPW0uZmluZCh3LnNoaWZ0KCksZCx2KSxkPW4uZXhwcj9tLmZpbHRlcihuLmV4cHIs
bi5zZXQpWzBdOm4uc2V0WzBdKTtpZihkKXtuPWY/e2V4cHI6dy5wb3AoKSxzZXQ6cyhmKX06bS5m
aW5kKHcucG9wKCksdy5sZW5ndGg9PT0xJiYod1swXT09PSJ+Inx8d1swXT09PSIrIikmJmQucGFy
ZW50Tm9kZT9kLnBhcmVudE5vZGU6ZCx2KSxqPW4uZXhwcj9tLmZpbHRlcihuLmV4cHIsbi5zZXQp
Om4uc2V0LHcubGVuZ3RoPjA/az1zKGopOnU9ITE7d2hpbGUody5sZW5ndGgpcT13LnBvcCgpLHI9
cSxvLnJlbGF0aXZlW3FdP3I9dy5wb3AoKTpxPSIiLHI9PW51bGwmJihyPWQpLG8ucmVsYXRpdmVb
cV0oayxyLHYpfWVsc2Ugaz13PVtdfWt8fChrPWopLGt8fG0uZXJyb3IocXx8Yik7aWYoZy5jYWxs
KGspPT09IltvYmplY3QgQXJyYXldIilpZighdSllLnB1c2guYXBwbHkoZSxrKTtlbHNlIGlmKGQm
JmQubm9kZVR5cGU9PT0xKWZvcih0PTA7a1t0XSE9bnVsbDt0Kyspa1t0XSYmKGtbdF09PT0hMHx8
a1t0XS5ub2RlVHlwZT09PTEmJm0uY29udGFpbnMoZCxrW3RdKSkmJmUucHVzaChqW3RdKTtlbHNl
IGZvcih0PTA7a1t0XSE9bnVsbDt0Kyspa1t0XSYma1t0XS5ub2RlVHlwZT09PTEmJmUucHVzaChq
W3RdKTtlbHNlIHMoayxlKTtsJiYobShsLGgsZSxmKSxtLnVuaXF1ZVNvcnQoZSkpO3JldHVybiBl
fTttLnVuaXF1ZVNvcnQ9ZnVuY3Rpb24oYSl7aWYodSl7aD1pLGEuc29ydCh1KTtpZihoKWZvcih2
YXIgYj0xO2I8YS5sZW5ndGg7YisrKWFbYl09PT1hW2ItMV0mJmEuc3BsaWNlKGItLSwxKX1yZXR1
cm4gYX0sbS5tYXRjaGVzPWZ1bmN0aW9uKGEsYil7cmV0dXJuIG0oYSxudWxsLG51bGwsYil9LG0u
bWF0Y2hlc1NlbGVjdG9yPWZ1bmN0aW9uKGEsYil7cmV0dXJuIG0oYixudWxsLG51bGwsW2FdKS5s
ZW5ndGg+MH0sbS5maW5kPWZ1bmN0aW9uKGEsYixjKXt2YXIgZCxlLGYsZyxoLGk7aWYoIWEpcmV0
dXJuW107Zm9yKGU9MCxmPW8ub3JkZXIubGVuZ3RoO2U8ZjtlKyspe2g9by5vcmRlcltlXTtpZihn
PW8ubGVmdE1hdGNoW2hdLmV4ZWMoYSkpe2k9Z1sxXSxnLnNwbGljZSgxLDEpO2lmKGkuc3Vic3Ry
KGkubGVuZ3RoLTEpIT09IlxcIil7Z1sxXT0oZ1sxXXx8IiIpLnJlcGxhY2UoaiwiIiksZD1vLmZp
bmRbaF0oZyxiLGMpO2lmKGQhPW51bGwpe2E9YS5yZXBsYWNlKG8ubWF0Y2hbaF0sIiIpO2JyZWFr
fX19fWR8fChkPXR5cGVvZiBiLmdldEVsZW1lbnRzQnlUYWdOYW1lIT0idW5kZWZpbmVkIj9iLmdl
dEVsZW1lbnRzQnlUYWdOYW1lKCIqIik6W10pO3JldHVybntzZXQ6ZCxleHByOmF9fSxtLmZpbHRl
cj1mdW5jdGlvbihhLGMsZCxlKXt2YXIgZixnLGgsaSxqLGssbCxuLHAscT1hLHI9W10scz1jLHQ9
YyYmY1swXSYmbS5pc1hNTChjWzBdKTt3aGlsZShhJiZjLmxlbmd0aCl7Zm9yKGggaW4gby5maWx0
ZXIpaWYoKGY9by5sZWZ0TWF0Y2hbaF0uZXhlYyhhKSkhPW51bGwmJmZbMl0pe2s9by5maWx0ZXJb
aF0sbD1mWzFdLGc9ITEsZi5zcGxpY2UoMSwxKTtpZihsLnN1YnN0cihsLmxlbmd0aC0xKT09PSJc
XCIpY29udGludWU7cz09PXImJihyPVtdKTtpZihvLnByZUZpbHRlcltoXSl7Zj1vLnByZUZpbHRl
cltoXShmLHMsZCxyLGUsdCk7aWYoIWYpZz1pPSEwO2Vsc2UgaWYoZj09PSEwKWNvbnRpbnVlfWlm
KGYpZm9yKG49MDsoaj1zW25dKSE9bnVsbDtuKyspaiYmKGk9ayhqLGYsbixzKSxwPWVeaSxkJiZp
IT1udWxsP3A/Zz0hMDpzW25dPSExOnAmJihyLnB1c2goaiksZz0hMCkpO2lmKGkhPT1iKXtkfHwo
cz1yKSxhPWEucmVwbGFjZShvLm1hdGNoW2hdLCIiKTtpZighZylyZXR1cm5bXTticmVha319aWYo
YT09PXEpaWYoZz09bnVsbCltLmVycm9yKGEpO2Vsc2UgYnJlYWs7cT1hfXJldHVybiBzfSxtLmVy
cm9yPWZ1bmN0aW9uKGEpe3Rocm93IG5ldyBFcnJvcigiU3ludGF4IGVycm9yLCB1bnJlY29nbml6
ZWQgZXhwcmVzc2lvbjogIithKX07dmFyIG49bS5nZXRUZXh0PWZ1bmN0aW9uKGEpe3ZhciBiLGMs
ZD1hLm5vZGVUeXBlLGU9IiI7aWYoZCl7aWYoZD09PTF8fGQ9PT05fHxkPT09MTEpe2lmKHR5cGVv
ZiBhLnRleHRDb250ZW50PT0ic3RyaW5nIilyZXR1cm4gYS50ZXh0Q29udGVudDtpZih0eXBlb2Yg
YS5pbm5lclRleHQ9PSJzdHJpbmciKXJldHVybiBhLmlubmVyVGV4dC5yZXBsYWNlKGssIiIpO2Zv
cihhPWEuZmlyc3RDaGlsZDthO2E9YS5uZXh0U2libGluZyllKz1uKGEpfWVsc2UgaWYoZD09PTN8
fGQ9PT00KXJldHVybiBhLm5vZGVWYWx1ZX1lbHNlIGZvcihiPTA7Yz1hW2JdO2IrKyljLm5vZGVU
eXBlIT09OCYmKGUrPW4oYykpO3JldHVybiBlfSxvPW0uc2VsZWN0b3JzPXtvcmRlcjpbIklEIiwi
TkFNRSIsIlRBRyJdLG1hdGNoOntJRDovIygoPzpbXHdcdTAwYzAtXHVGRkZGXC1dfFxcLikrKS8s
Q0xBU1M6L1wuKCg/Oltcd1x1MDBjMC1cdUZGRkZcLV18XFwuKSspLyxOQU1FOi9cW25hbWU9Wyci
XSooKD86W1x3XHUwMGMwLVx1RkZGRlwtXXxcXC4pKylbJyJdKlxdLyxBVFRSOi9cW1xzKigoPzpb
XHdcdTAwYzAtXHVGRkZGXC1dfFxcLikrKVxzKig/OihcUz89KVxzKig/OihbJyJdKSguKj8pXDN8
KCM/KD86W1x3XHUwMGMwLVx1RkZGRlwtXXxcXC4pKil8KXwpXHMqXF0vLFRBRzovXigoPzpbXHdc
dTAwYzAtXHVGRkZGXCpcLV18XFwuKSspLyxDSElMRDovOihvbmx5fG50aHxsYXN0fGZpcnN0KS1j
aGlsZCg/OlwoXHMqKGV2ZW58b2RkfCg/OlsrXC1dP1xkK3woPzpbK1wtXT9cZCopP25ccyooPzpb
K1wtXVxzKlxkKyk/KSlccypcKSk/LyxQT1M6LzoobnRofGVxfGd0fGx0fGZpcnN0fGxhc3R8ZXZl
bnxvZGQpKD86XCgoXGQqKVwpKT8oPz1bXlwtXXwkKS8sUFNFVURPOi86KCg/Oltcd1x1MDBjMC1c
dUZGRkZcLV18XFwuKSspKD86XCgoWyciXT8pKCg/OlwoW15cKV0rXCl8W15cKFwpXSopKylcMlwp
KT8vfSxsZWZ0TWF0Y2g6e30sYXR0ck1hcDp7ImNsYXNzIjoiY2xhc3NOYW1lIiwiZm9yIjoiaHRt
bEZvciJ9LGF0dHJIYW5kbGU6e2hyZWY6ZnVuY3Rpb24oYSl7cmV0dXJuIGEuZ2V0QXR0cmlidXRl
KCJocmVmIil9LHR5cGU6ZnVuY3Rpb24oYSl7cmV0dXJuIGEuZ2V0QXR0cmlidXRlKCJ0eXBlIil9
fSxyZWxhdGl2ZTp7IisiOmZ1bmN0aW9uKGEsYil7dmFyIGM9dHlwZW9mIGI9PSJzdHJpbmciLGQ9
YyYmIWwudGVzdChiKSxlPWMmJiFkO2QmJihiPWIudG9Mb3dlckNhc2UoKSk7Zm9yKHZhciBmPTAs
Zz1hLmxlbmd0aCxoO2Y8ZztmKyspaWYoaD1hW2ZdKXt3aGlsZSgoaD1oLnByZXZpb3VzU2libGlu
ZykmJmgubm9kZVR5cGUhPT0xKTthW2ZdPWV8fGgmJmgubm9kZU5hbWUudG9Mb3dlckNhc2UoKT09
PWI/aHx8ITE6aD09PWJ9ZSYmbS5maWx0ZXIoYixhLCEwKX0sIj4iOmZ1bmN0aW9uKGEsYil7dmFy
IGMsZD10eXBlb2YgYj09InN0cmluZyIsZT0wLGY9YS5sZW5ndGg7aWYoZCYmIWwudGVzdChiKSl7
Yj1iLnRvTG93ZXJDYXNlKCk7Zm9yKDtlPGY7ZSsrKXtjPWFbZV07aWYoYyl7dmFyIGc9Yy5wYXJl
bnROb2RlO2FbZV09Zy5ub2RlTmFtZS50b0xvd2VyQ2FzZSgpPT09Yj9nOiExfX19ZWxzZXtmb3Io
O2U8ZjtlKyspYz1hW2VdLGMmJihhW2VdPWQ/Yy5wYXJlbnROb2RlOmMucGFyZW50Tm9kZT09PWIp
O2QmJm0uZmlsdGVyKGIsYSwhMCl9fSwiIjpmdW5jdGlvbihhLGIsYyl7dmFyIGQsZj1lKyssZz14
O3R5cGVvZiBiPT0ic3RyaW5nIiYmIWwudGVzdChiKSYmKGI9Yi50b0xvd2VyQ2FzZSgpLGQ9Yixn
PXcpLGcoInBhcmVudE5vZGUiLGIsZixhLGQsYyl9LCJ+IjpmdW5jdGlvbihhLGIsYyl7dmFyIGQs
Zj1lKyssZz14O3R5cGVvZiBiPT0ic3RyaW5nIiYmIWwudGVzdChiKSYmKGI9Yi50b0xvd2VyQ2Fz
ZSgpLGQ9YixnPXcpLGcoInByZXZpb3VzU2libGluZyIsYixmLGEsZCxjKX19LGZpbmQ6e0lEOmZ1
bmN0aW9uKGEsYixjKXtpZih0eXBlb2YgYi5nZXRFbGVtZW50QnlJZCE9InVuZGVmaW5lZCImJiFj
KXt2YXIgZD1iLmdldEVsZW1lbnRCeUlkKGFbMV0pO3JldHVybiBkJiZkLnBhcmVudE5vZGU/W2Rd
OltdfX0sTkFNRTpmdW5jdGlvbihhLGIpe2lmKHR5cGVvZiBiLmdldEVsZW1lbnRzQnlOYW1lIT0i
dW5kZWZpbmVkIil7dmFyIGM9W10sZD1iLmdldEVsZW1lbnRzQnlOYW1lKGFbMV0pO2Zvcih2YXIg
ZT0wLGY9ZC5sZW5ndGg7ZTxmO2UrKylkW2VdLmdldEF0dHJpYnV0ZSgibmFtZSIpPT09YVsxXSYm
Yy5wdXNoKGRbZV0pO3JldHVybiBjLmxlbmd0aD09PTA/bnVsbDpjfX0sVEFHOmZ1bmN0aW9uKGEs
Yil7aWYodHlwZW9mIGIuZ2V0RWxlbWVudHNCeVRhZ05hbWUhPSJ1bmRlZmluZWQiKXJldHVybiBi
LmdldEVsZW1lbnRzQnlUYWdOYW1lKGFbMV0pfX0scHJlRmlsdGVyOntDTEFTUzpmdW5jdGlvbihh
LGIsYyxkLGUsZil7YT0iICIrYVsxXS5yZXBsYWNlKGosIiIpKyIgIjtpZihmKXJldHVybiBhO2Zv
cih2YXIgZz0wLGg7KGg9YltnXSkhPW51bGw7ZysrKWgmJihlXihoLmNsYXNzTmFtZSYmKCIgIito
LmNsYXNzTmFtZSsiICIpLnJlcGxhY2UoL1tcdFxuXHJdL2csIiAiKS5pbmRleE9mKGEpPj0wKT9j
fHxkLnB1c2goaCk6YyYmKGJbZ109ITEpKTtyZXR1cm4hMX0sSUQ6ZnVuY3Rpb24oYSl7cmV0dXJu
IGFbMV0ucmVwbGFjZShqLCIiKX0sVEFHOmZ1bmN0aW9uKGEsYil7cmV0dXJuIGFbMV0ucmVwbGFj
ZShqLCIiKS50b0xvd2VyQ2FzZSgpfSxDSElMRDpmdW5jdGlvbihhKXtpZihhWzFdPT09Im50aCIp
e2FbMl18fG0uZXJyb3IoYVswXSksYVsyXT1hWzJdLnJlcGxhY2UoL15cK3xccyovZywiIik7dmFy
IGI9LygtPykoXGQqKSg/Om4oWytcLV0/XGQqKSk/Ly5leGVjKGFbMl09PT0iZXZlbiImJiIybiJ8
fGFbMl09PT0ib2RkIiYmIjJuKzEifHwhL1xELy50ZXN0KGFbMl0pJiYiMG4rIithWzJdfHxhWzJd
KTthWzJdPWJbMV0rKGJbMl18fDEpLTAsYVszXT1iWzNdLTB9ZWxzZSBhWzJdJiZtLmVycm9yKGFb
MF0pO2FbMF09ZSsrO3JldHVybiBhfSxBVFRSOmZ1bmN0aW9uKGEsYixjLGQsZSxmKXt2YXIgZz1h
WzFdPWFbMV0ucmVwbGFjZShqLCIiKTshZiYmby5hdHRyTWFwW2ddJiYoYVsxXT1vLmF0dHJNYXBb
Z10pLGFbNF09KGFbNF18fGFbNV18fCIiKS5yZXBsYWNlKGosIiIpLGFbMl09PT0ifj0iJiYoYVs0
XT0iICIrYVs0XSsiICIpO3JldHVybiBhfSxQU0VVRE86ZnVuY3Rpb24oYixjLGQsZSxmKXtpZihi
WzFdPT09Im5vdCIpaWYoKGEuZXhlYyhiWzNdKXx8IiIpLmxlbmd0aD4xfHwvXlx3Ly50ZXN0KGJb
M10pKWJbM109bShiWzNdLG51bGwsbnVsbCxjKTtlbHNle3ZhciBnPW0uZmlsdGVyKGJbM10sYyxk
LCEwXmYpO2R8fGUucHVzaC5hcHBseShlLGcpO3JldHVybiExfWVsc2UgaWYoby5tYXRjaC5QT1Mu
dGVzdChiWzBdKXx8by5tYXRjaC5DSElMRC50ZXN0KGJbMF0pKXJldHVybiEwO3JldHVybiBifSxQ
T1M6ZnVuY3Rpb24oYSl7YS51bnNoaWZ0KCEwKTtyZXR1cm4gYX19LGZpbHRlcnM6e2VuYWJsZWQ6
ZnVuY3Rpb24oYSl7cmV0dXJuIGEuZGlzYWJsZWQ9PT0hMSYmYS50eXBlIT09ImhpZGRlbiJ9LGRp
c2FibGVkOmZ1bmN0aW9uKGEpe3JldHVybiBhLmRpc2FibGVkPT09ITB9LGNoZWNrZWQ6ZnVuY3Rp
b24oYSl7cmV0dXJuIGEuY2hlY2tlZD09PSEwfSxzZWxlY3RlZDpmdW5jdGlvbihhKXthLnBhcmVu
dE5vZGUmJmEucGFyZW50Tm9kZS5zZWxlY3RlZEluZGV4O3JldHVybiBhLnNlbGVjdGVkPT09ITB9
LHBhcmVudDpmdW5jdGlvbihhKXtyZXR1cm4hIWEuZmlyc3RDaGlsZH0sZW1wdHk6ZnVuY3Rpb24o
YSl7cmV0dXJuIWEuZmlyc3RDaGlsZH0saGFzOmZ1bmN0aW9uKGEsYixjKXtyZXR1cm4hIW0oY1sz
XSxhKS5sZW5ndGh9LGhlYWRlcjpmdW5jdGlvbihhKXtyZXR1cm4vaFxkL2kudGVzdChhLm5vZGVO
YW1lKX0sdGV4dDpmdW5jdGlvbihhKXt2YXIgYj1hLmdldEF0dHJpYnV0ZSgidHlwZSIpLGM9YS50
eXBlO3JldHVybiBhLm5vZGVOYW1lLnRvTG93ZXJDYXNlKCk9PT0iaW5wdXQiJiYidGV4dCI9PT1j
JiYoYj09PWN8fGI9PT1udWxsKX0scmFkaW86ZnVuY3Rpb24oYSl7cmV0dXJuIGEubm9kZU5hbWUu
dG9Mb3dlckNhc2UoKT09PSJpbnB1dCImJiJyYWRpbyI9PT1hLnR5cGV9LGNoZWNrYm94OmZ1bmN0
aW9uKGEpe3JldHVybiBhLm5vZGVOYW1lLnRvTG93ZXJDYXNlKCk9PT0iaW5wdXQiJiYiY2hlY2ti
b3giPT09YS50eXBlfSxmaWxlOmZ1bmN0aW9uKGEpe3JldHVybiBhLm5vZGVOYW1lLnRvTG93ZXJD
YXNlKCk9PT0iaW5wdXQiJiYiZmlsZSI9PT1hLnR5cGV9LHBhc3N3b3JkOmZ1bmN0aW9uKGEpe3Jl
dHVybiBhLm5vZGVOYW1lLnRvTG93ZXJDYXNlKCk9PT0iaW5wdXQiJiYicGFzc3dvcmQiPT09YS50
eXBlfSxzdWJtaXQ6ZnVuY3Rpb24oYSl7dmFyIGI9YS5ub2RlTmFtZS50b0xvd2VyQ2FzZSgpO3Jl
dHVybihiPT09ImlucHV0Inx8Yj09PSJidXR0b24iKSYmInN1Ym1pdCI9PT1hLnR5cGV9LGltYWdl
OmZ1bmN0aW9uKGEpe3JldHVybiBhLm5vZGVOYW1lLnRvTG93ZXJDYXNlKCk9PT0iaW5wdXQiJiYi
aW1hZ2UiPT09YS50eXBlfSxyZXNldDpmdW5jdGlvbihhKXt2YXIgYj1hLm5vZGVOYW1lLnRvTG93
ZXJDYXNlKCk7cmV0dXJuKGI9PT0iaW5wdXQifHxiPT09ImJ1dHRvbiIpJiYicmVzZXQiPT09YS50
eXBlfSxidXR0b246ZnVuY3Rpb24oYSl7dmFyIGI9YS5ub2RlTmFtZS50b0xvd2VyQ2FzZSgpO3Jl
dHVybiBiPT09ImlucHV0IiYmImJ1dHRvbiI9PT1hLnR5cGV8fGI9PT0iYnV0dG9uIn0saW5wdXQ6
ZnVuY3Rpb24oYSl7cmV0dXJuL2lucHV0fHNlbGVjdHx0ZXh0YXJlYXxidXR0b24vaS50ZXN0KGEu
bm9kZU5hbWUpfSxmb2N1czpmdW5jdGlvbihhKXtyZXR1cm4gYT09PWEub3duZXJEb2N1bWVudC5h
Y3RpdmVFbGVtZW50fX0sc2V0RmlsdGVyczp7Zmlyc3Q6ZnVuY3Rpb24oYSxiKXtyZXR1cm4gYj09
PTB9LGxhc3Q6ZnVuY3Rpb24oYSxiLGMsZCl7cmV0dXJuIGI9PT1kLmxlbmd0aC0xfSxldmVuOmZ1
bmN0aW9uKGEsYil7cmV0dXJuIGIlMj09PTB9LG9kZDpmdW5jdGlvbihhLGIpe3JldHVybiBiJTI9
PT0xfSxsdDpmdW5jdGlvbihhLGIsYyl7cmV0dXJuIGI8Y1szXS0wfSxndDpmdW5jdGlvbihhLGIs
Yyl7cmV0dXJuIGI+Y1szXS0wfSxudGg6ZnVuY3Rpb24oYSxiLGMpe3JldHVybiBjWzNdLTA9PT1i
fSxlcTpmdW5jdGlvbihhLGIsYyl7cmV0dXJuIGNbM10tMD09PWJ9fSxmaWx0ZXI6e1BTRVVETzpm
dW5jdGlvbihhLGIsYyxkKXt2YXIgZT1iWzFdLGY9by5maWx0ZXJzW2VdO2lmKGYpcmV0dXJuIGYo
YSxjLGIsZCk7aWYoZT09PSJjb250YWlucyIpcmV0dXJuKGEudGV4dENvbnRlbnR8fGEuaW5uZXJU
ZXh0fHxuKFthXSl8fCIiKS5pbmRleE9mKGJbM10pPj0wO2lmKGU9PT0ibm90Iil7dmFyIGc9Ylsz
XTtmb3IodmFyIGg9MCxpPWcubGVuZ3RoO2g8aTtoKyspaWYoZ1toXT09PWEpcmV0dXJuITE7cmV0
dXJuITB9bS5lcnJvcihlKX0sQ0hJTEQ6ZnVuY3Rpb24oYSxiKXt2YXIgYyxlLGYsZyxoLGksaixr
PWJbMV0sbD1hO3N3aXRjaChrKXtjYXNlIm9ubHkiOmNhc2UiZmlyc3QiOndoaWxlKGw9bC5wcmV2
aW91c1NpYmxpbmcpaWYobC5ub2RlVHlwZT09PTEpcmV0dXJuITE7aWYoaz09PSJmaXJzdCIpcmV0
dXJuITA7bD1hO2Nhc2UibGFzdCI6d2hpbGUobD1sLm5leHRTaWJsaW5nKWlmKGwubm9kZVR5cGU9
PT0xKXJldHVybiExO3JldHVybiEwO2Nhc2UibnRoIjpjPWJbMl0sZT1iWzNdO2lmKGM9PT0xJiZl
PT09MClyZXR1cm4hMDtmPWJbMF0sZz1hLnBhcmVudE5vZGU7aWYoZyYmKGdbZF0hPT1mfHwhYS5u
b2RlSW5kZXgpKXtpPTA7Zm9yKGw9Zy5maXJzdENoaWxkO2w7bD1sLm5leHRTaWJsaW5nKWwubm9k
ZVR5cGU9PT0xJiYobC5ub2RlSW5kZXg9KytpKTtnW2RdPWZ9aj1hLm5vZGVJbmRleC1lO3JldHVy
biBjPT09MD9qPT09MDpqJWM9PT0wJiZqL2M+PTB9fSxJRDpmdW5jdGlvbihhLGIpe3JldHVybiBh
Lm5vZGVUeXBlPT09MSYmYS5nZXRBdHRyaWJ1dGUoImlkIik9PT1ifSxUQUc6ZnVuY3Rpb24oYSxi
KXtyZXR1cm4gYj09PSIqIiYmYS5ub2RlVHlwZT09PTF8fCEhYS5ub2RlTmFtZSYmYS5ub2RlTmFt
ZS50b0xvd2VyQ2FzZSgpPT09Yn0sQ0xBU1M6ZnVuY3Rpb24oYSxiKXtyZXR1cm4oIiAiKyhhLmNs
YXNzTmFtZXx8YS5nZXRBdHRyaWJ1dGUoImNsYXNzIikpKyIgIikuaW5kZXhPZihiKT4tMX0sQVRU
UjpmdW5jdGlvbihhLGIpe3ZhciBjPWJbMV0sZD1tLmF0dHI/bS5hdHRyKGEsYyk6by5hdHRySGFu
ZGxlW2NdP28uYXR0ckhhbmRsZVtjXShhKTphW2NdIT1udWxsP2FbY106YS5nZXRBdHRyaWJ1dGUo
YyksZT1kKyIiLGY9YlsyXSxnPWJbNF07cmV0dXJuIGQ9PW51bGw/Zj09PSIhPSI6IWYmJm0uYXR0
cj9kIT1udWxsOmY9PT0iPSI/ZT09PWc6Zj09PSIqPSI/ZS5pbmRleE9mKGcpPj0wOmY9PT0ifj0i
PygiICIrZSsiICIpLmluZGV4T2YoZyk+PTA6Zz9mPT09IiE9Ij9lIT09ZzpmPT09Il49Ij9lLmlu
ZGV4T2YoZyk9PT0wOmY9PT0iJD0iP2Uuc3Vic3RyKGUubGVuZ3RoLWcubGVuZ3RoKT09PWc6Zj09
PSJ8PSI/ZT09PWd8fGUuc3Vic3RyKDAsZy5sZW5ndGgrMSk9PT1nKyItIjohMTplJiZkIT09ITF9
LFBPUzpmdW5jdGlvbihhLGIsYyxkKXt2YXIgZT1iWzJdLGY9by5zZXRGaWx0ZXJzW2VdO2lmKGYp
cmV0dXJuIGYoYSxjLGIsZCl9fX0scD1vLm1hdGNoLlBPUyxxPWZ1bmN0aW9uKGEsYil7cmV0dXJu
IlxcIisoYi0wKzEpfTtmb3IodmFyIHIgaW4gby5tYXRjaClvLm1hdGNoW3JdPW5ldyBSZWdFeHAo
by5tYXRjaFtyXS5zb3VyY2UrLyg/IVteXFtdKlxdKSg/IVteXChdKlwpKS8uc291cmNlKSxvLmxl
ZnRNYXRjaFtyXT1uZXcgUmVnRXhwKC8oXig/Oi58XHJ8XG4pKj8pLy5zb3VyY2Urby5tYXRjaFty
XS5zb3VyY2UucmVwbGFjZSgvXFwoXGQrKS9nLHEpKTtvLm1hdGNoLmdsb2JhbFBPUz1wO3ZhciBz
PWZ1bmN0aW9uKGEsYil7YT1BcnJheS5wcm90b3R5cGUuc2xpY2UuY2FsbChhLDApO2lmKGIpe2Iu
cHVzaC5hcHBseShiLGEpO3JldHVybiBifXJldHVybiBhfTt0cnl7QXJyYXkucHJvdG90eXBlLnNs
aWNlLmNhbGwoYy5kb2N1bWVudEVsZW1lbnQuY2hpbGROb2RlcywwKVswXS5ub2RlVHlwZX1jYXRj
aCh0KXtzPWZ1bmN0aW9uKGEsYil7dmFyIGM9MCxkPWJ8fFtdO2lmKGcuY2FsbChhKT09PSJbb2Jq
ZWN0IEFycmF5XSIpQXJyYXkucHJvdG90eXBlLnB1c2guYXBwbHkoZCxhKTtlbHNlIGlmKHR5cGVv
ZiBhLmxlbmd0aD09Im51bWJlciIpZm9yKHZhciBlPWEubGVuZ3RoO2M8ZTtjKyspZC5wdXNoKGFb
Y10pO2Vsc2UgZm9yKDthW2NdO2MrKylkLnB1c2goYVtjXSk7cmV0dXJuIGR9fXZhciB1LHY7Yy5k
b2N1bWVudEVsZW1lbnQuY29tcGFyZURvY3VtZW50UG9zaXRpb24/dT1mdW5jdGlvbihhLGIpe2lm
KGE9PT1iKXtoPSEwO3JldHVybiAwfWlmKCFhLmNvbXBhcmVEb2N1bWVudFBvc2l0aW9ufHwhYi5j
b21wYXJlRG9jdW1lbnRQb3NpdGlvbilyZXR1cm4gYS5jb21wYXJlRG9jdW1lbnRQb3NpdGlvbj8t
MToxO3JldHVybiBhLmNvbXBhcmVEb2N1bWVudFBvc2l0aW9uKGIpJjQ/LTE6MX06KHU9ZnVuY3Rp
b24oYSxiKXtpZihhPT09Yil7aD0hMDtyZXR1cm4gMH1pZihhLnNvdXJjZUluZGV4JiZiLnNvdXJj
ZUluZGV4KXJldHVybiBhLnNvdXJjZUluZGV4LWIuc291cmNlSW5kZXg7dmFyIGMsZCxlPVtdLGY9
W10sZz1hLnBhcmVudE5vZGUsaT1iLnBhcmVudE5vZGUsaj1nO2lmKGc9PT1pKXJldHVybiB2KGEs
Yik7aWYoIWcpcmV0dXJuLTE7aWYoIWkpcmV0dXJuIDE7d2hpbGUoaillLnVuc2hpZnQoaiksaj1q
LnBhcmVudE5vZGU7aj1pO3doaWxlKGopZi51bnNoaWZ0KGopLGo9ai5wYXJlbnROb2RlO2M9ZS5s
ZW5ndGgsZD1mLmxlbmd0aDtmb3IodmFyIGs9MDtrPGMmJms8ZDtrKyspaWYoZVtrXSE9PWZba10p
cmV0dXJuIHYoZVtrXSxmW2tdKTtyZXR1cm4gaz09PWM/dihhLGZba10sLTEpOnYoZVtrXSxiLDEp
fSx2PWZ1bmN0aW9uKGEsYixjKXtpZihhPT09YilyZXR1cm4gYzt2YXIgZD1hLm5leHRTaWJsaW5n
O3doaWxlKGQpe2lmKGQ9PT1iKXJldHVybi0xO2Q9ZC5uZXh0U2libGluZ31yZXR1cm4gMX0pLGZ1
bmN0aW9uKCl7dmFyIGE9Yy5jcmVhdGVFbGVtZW50KCJkaXYiKSxkPSJzY3JpcHQiKyhuZXcgRGF0
ZSkuZ2V0VGltZSgpLGU9Yy5kb2N1bWVudEVsZW1lbnQ7YS5pbm5lckhUTUw9IjxhIG5hbWU9JyIr
ZCsiJy8+IixlLmluc2VydEJlZm9yZShhLGUuZmlyc3RDaGlsZCksYy5nZXRFbGVtZW50QnlJZChk
KSYmKG8uZmluZC5JRD1mdW5jdGlvbihhLGMsZCl7aWYodHlwZW9mIGMuZ2V0RWxlbWVudEJ5SWQh
PSJ1bmRlZmluZWQiJiYhZCl7dmFyIGU9Yy5nZXRFbGVtZW50QnlJZChhWzFdKTtyZXR1cm4gZT9l
LmlkPT09YVsxXXx8dHlwZW9mIGUuZ2V0QXR0cmlidXRlTm9kZSE9InVuZGVmaW5lZCImJmUuZ2V0
QXR0cmlidXRlTm9kZSgiaWQiKS5ub2RlVmFsdWU9PT1hWzFdP1tlXTpiOltdfX0sby5maWx0ZXIu
SUQ9ZnVuY3Rpb24oYSxiKXt2YXIgYz10eXBlb2YgYS5nZXRBdHRyaWJ1dGVOb2RlIT0idW5kZWZp
bmVkIiYmYS5nZXRBdHRyaWJ1dGVOb2RlKCJpZCIpO3JldHVybiBhLm5vZGVUeXBlPT09MSYmYyYm
Yy5ub2RlVmFsdWU9PT1ifSksZS5yZW1vdmVDaGlsZChhKSxlPWE9bnVsbH0oKSxmdW5jdGlvbigp
e3ZhciBhPWMuY3JlYXRlRWxlbWVudCgiZGl2Iik7YS5hcHBlbmRDaGlsZChjLmNyZWF0ZUNvbW1l
bnQoIiIpKSxhLmdldEVsZW1lbnRzQnlUYWdOYW1lKCIqIikubGVuZ3RoPjAmJihvLmZpbmQuVEFH
PWZ1bmN0aW9uKGEsYil7dmFyIGM9Yi5nZXRFbGVtZW50c0J5VGFnTmFtZShhWzFdKTtpZihhWzFd
PT09IioiKXt2YXIgZD1bXTtmb3IodmFyIGU9MDtjW2VdO2UrKyljW2VdLm5vZGVUeXBlPT09MSYm
ZC5wdXNoKGNbZV0pO2M9ZH1yZXR1cm4gY30pLGEuaW5uZXJIVE1MPSI8YSBocmVmPScjJz48L2E+
IixhLmZpcnN0Q2hpbGQmJnR5cGVvZiBhLmZpcnN0Q2hpbGQuZ2V0QXR0cmlidXRlIT0idW5kZWZp
bmVkIiYmYS5maXJzdENoaWxkLmdldEF0dHJpYnV0ZSgiaHJlZiIpIT09IiMiJiYoby5hdHRySGFu
ZGxlLmhyZWY9ZnVuY3Rpb24oYSl7cmV0dXJuIGEuZ2V0QXR0cmlidXRlKCJocmVmIiwyKX0pLGE9
bnVsbH0oKSxjLnF1ZXJ5U2VsZWN0b3JBbGwmJmZ1bmN0aW9uKCl7dmFyIGE9bSxiPWMuY3JlYXRl
RWxlbWVudCgiZGl2IiksZD0iX19zaXp6bGVfXyI7Yi5pbm5lckhUTUw9IjxwIGNsYXNzPSdURVNU
Jz48L3A+IjtpZighYi5xdWVyeVNlbGVjdG9yQWxsfHxiLnF1ZXJ5U2VsZWN0b3JBbGwoIi5URVNU
IikubGVuZ3RoIT09MCl7bT1mdW5jdGlvbihiLGUsZixnKXtlPWV8fGM7aWYoIWcmJiFtLmlzWE1M
KGUpKXt2YXIgaD0vXihcdyskKXxeXC4oW1x3XC1dKyQpfF4jKFtcd1wtXSskKS8uZXhlYyhiKTtp
ZihoJiYoZS5ub2RlVHlwZT09PTF8fGUubm9kZVR5cGU9PT05KSl7aWYoaFsxXSlyZXR1cm4gcyhl
LmdldEVsZW1lbnRzQnlUYWdOYW1lKGIpLGYpO2lmKGhbMl0mJm8uZmluZC5DTEFTUyYmZS5nZXRF
bGVtZW50c0J5Q2xhc3NOYW1lKXJldHVybiBzKGUuZ2V0RWxlbWVudHNCeUNsYXNzTmFtZShoWzJd
KSxmKX1pZihlLm5vZGVUeXBlPT09OSl7aWYoYj09PSJib2R5IiYmZS5ib2R5KXJldHVybiBzKFtl
LmJvZHldLGYpO2lmKGgmJmhbM10pe3ZhciBpPWUuZ2V0RWxlbWVudEJ5SWQoaFszXSk7aWYoIWl8
fCFpLnBhcmVudE5vZGUpcmV0dXJuIHMoW10sZik7aWYoaS5pZD09PWhbM10pcmV0dXJuIHMoW2ld
LGYpfXRyeXtyZXR1cm4gcyhlLnF1ZXJ5U2VsZWN0b3JBbGwoYiksZil9Y2F0Y2goail7fX1lbHNl
IGlmKGUubm9kZVR5cGU9PT0xJiZlLm5vZGVOYW1lLnRvTG93ZXJDYXNlKCkhPT0ib2JqZWN0Iil7
dmFyIGs9ZSxsPWUuZ2V0QXR0cmlidXRlKCJpZCIpLG49bHx8ZCxwPWUucGFyZW50Tm9kZSxxPS9e
XHMqWyt+XS8udGVzdChiKTtsP249bi5yZXBsYWNlKC8nL2csIlxcJCYiKTplLnNldEF0dHJpYnV0
ZSgiaWQiLG4pLHEmJnAmJihlPWUucGFyZW50Tm9kZSk7dHJ5e2lmKCFxfHxwKXJldHVybiBzKGUu
cXVlcnlTZWxlY3RvckFsbCgiW2lkPSciK24rIiddICIrYiksZil9Y2F0Y2gocil7fWZpbmFsbHl7
bHx8ay5yZW1vdmVBdHRyaWJ1dGUoImlkIil9fX1yZXR1cm4gYShiLGUsZixnKX07Zm9yKHZhciBl
IGluIGEpbVtlXT1hW2VdO2I9bnVsbH19KCksZnVuY3Rpb24oKXt2YXIgYT1jLmRvY3VtZW50RWxl
bWVudCxiPWEubWF0Y2hlc1NlbGVjdG9yfHxhLm1vek1hdGNoZXNTZWxlY3Rvcnx8YS53ZWJraXRN
YXRjaGVzU2VsZWN0b3J8fGEubXNNYXRjaGVzU2VsZWN0b3I7aWYoYil7dmFyIGQ9IWIuY2FsbChj
LmNyZWF0ZUVsZW1lbnQoImRpdiIpLCJkaXYiKSxlPSExO3RyeXtiLmNhbGwoYy5kb2N1bWVudEVs
ZW1lbnQsIlt0ZXN0IT0nJ106c2l6emxlIil9Y2F0Y2goZil7ZT0hMH1tLm1hdGNoZXNTZWxlY3Rv
cj1mdW5jdGlvbihhLGMpe2M9Yy5yZXBsYWNlKC9cPVxzKihbXiciXF1dKilccypcXS9nLCI9JyQx
J10iKTtpZighbS5pc1hNTChhKSl0cnl7aWYoZXx8IW8ubWF0Y2guUFNFVURPLnRlc3QoYykmJiEv
IT0vLnRlc3QoYykpe3ZhciBmPWIuY2FsbChhLGMpO2lmKGZ8fCFkfHxhLmRvY3VtZW50JiZhLmRv
Y3VtZW50Lm5vZGVUeXBlIT09MTEpcmV0dXJuIGZ9fWNhdGNoKGcpe31yZXR1cm4gbShjLG51bGws
bnVsbCxbYV0pLmxlbmd0aD4wfX19KCksZnVuY3Rpb24oKXt2YXIgYT1jLmNyZWF0ZUVsZW1lbnQo
ImRpdiIpO2EuaW5uZXJIVE1MPSI8ZGl2IGNsYXNzPSd0ZXN0IGUnPjwvZGl2PjxkaXYgY2xhc3M9
J3Rlc3QnPjwvZGl2PiI7aWYoISFhLmdldEVsZW1lbnRzQnlDbGFzc05hbWUmJmEuZ2V0RWxlbWVu
dHNCeUNsYXNzTmFtZSgiZSIpLmxlbmd0aCE9PTApe2EubGFzdENoaWxkLmNsYXNzTmFtZT0iZSI7
aWYoYS5nZXRFbGVtZW50c0J5Q2xhc3NOYW1lKCJlIikubGVuZ3RoPT09MSlyZXR1cm47by5vcmRl
ci5zcGxpY2UoMSwwLCJDTEFTUyIpLG8uZmluZC5DTEFTUz1mdW5jdGlvbihhLGIsYyl7aWYodHlw
ZW9mIGIuZ2V0RWxlbWVudHNCeUNsYXNzTmFtZSE9InVuZGVmaW5lZCImJiFjKXJldHVybiBiLmdl
dEVsZW1lbnRzQnlDbGFzc05hbWUoYVsxXSl9LGE9bnVsbH19KCksYy5kb2N1bWVudEVsZW1lbnQu
Y29udGFpbnM/bS5jb250YWlucz1mdW5jdGlvbihhLGIpe3JldHVybiBhIT09YiYmKGEuY29udGFp
bnM/YS5jb250YWlucyhiKTohMCl9OmMuZG9jdW1lbnRFbGVtZW50LmNvbXBhcmVEb2N1bWVudFBv
c2l0aW9uP20uY29udGFpbnM9ZnVuY3Rpb24oYSxiKXtyZXR1cm4hIShhLmNvbXBhcmVEb2N1bWVu
dFBvc2l0aW9uKGIpJjE2KX06bS5jb250YWlucz1mdW5jdGlvbigpe3JldHVybiExfSxtLmlzWE1M
PWZ1bmN0aW9uKGEpe3ZhciBiPShhP2Eub3duZXJEb2N1bWVudHx8YTowKS5kb2N1bWVudEVsZW1l
bnQ7cmV0dXJuIGI/Yi5ub2RlTmFtZSE9PSJIVE1MIjohMX07dmFyIHk9ZnVuY3Rpb24oYSxiLGMp
e3ZhciBkLGU9W10sZj0iIixnPWIubm9kZVR5cGU/W2JdOmI7d2hpbGUoZD1vLm1hdGNoLlBTRVVE
Ty5leGVjKGEpKWYrPWRbMF0sYT1hLnJlcGxhY2Uoby5tYXRjaC5QU0VVRE8sIiIpO2E9by5yZWxh
dGl2ZVthXT9hKyIqIjphO2Zvcih2YXIgaD0wLGk9Zy5sZW5ndGg7aDxpO2grKyltKGEsZ1toXSxl
LGMpO3JldHVybiBtLmZpbHRlcihmLGUpfTttLmF0dHI9Zi5hdHRyLG0uc2VsZWN0b3JzLmF0dHJN
YXA9e30sZi5maW5kPW0sZi5leHByPW0uc2VsZWN0b3JzLGYuZXhwclsiOiJdPWYuZXhwci5maWx0
ZXJzLGYudW5pcXVlPW0udW5pcXVlU29ydCxmLnRleHQ9bS5nZXRUZXh0LGYuaXNYTUxEb2M9bS5p
c1hNTCxmLmNvbnRhaW5zPW0uY29udGFpbnN9KCk7dmFyIEw9L1VudGlsJC8sTT0vXig/OnBhcmVu
dHN8cHJldlVudGlsfHByZXZBbGwpLyxOPS8sLyxPPS9eLlteOiNcW1wuLF0qJC8sUD1BcnJheS5w
cm90b3R5cGUuc2xpY2UsUT1mLmV4cHIubWF0Y2guZ2xvYmFsUE9TLFI9e2NoaWxkcmVuOiEwLGNv
bnRlbnRzOiEwLG5leHQ6ITAscHJldjohMH07Zi5mbi5leHRlbmQoe2ZpbmQ6ZnVuY3Rpb24oYSl7
dmFyIGI9dGhpcyxjLGQ7aWYodHlwZW9mIGEhPSJzdHJpbmciKXJldHVybiBmKGEpLmZpbHRlcihm
dW5jdGlvbigpe2ZvcihjPTAsZD1iLmxlbmd0aDtjPGQ7YysrKWlmKGYuY29udGFpbnMoYltjXSx0
aGlzKSlyZXR1cm4hMH0pO3ZhciBlPXRoaXMucHVzaFN0YWNrKCIiLCJmaW5kIixhKSxnLGgsaTtm
b3IoYz0wLGQ9dGhpcy5sZW5ndGg7YzxkO2MrKyl7Zz1lLmxlbmd0aCxmLmZpbmQoYSx0aGlzW2Nd
LGUpO2lmKGM+MClmb3IoaD1nO2g8ZS5sZW5ndGg7aCsrKWZvcihpPTA7aTxnO2krKylpZihlW2ld
PT09ZVtoXSl7ZS5zcGxpY2UoaC0tLDEpO2JyZWFrfX1yZXR1cm4gZX0saGFzOmZ1bmN0aW9uKGEp
e3ZhciBiPWYoYSk7cmV0dXJuIHRoaXMuZmlsdGVyKGZ1bmN0aW9uKCl7Zm9yKHZhciBhPTAsYz1i
Lmxlbmd0aDthPGM7YSsrKWlmKGYuY29udGFpbnModGhpcyxiW2FdKSlyZXR1cm4hMH0pfSxub3Q6
ZnVuY3Rpb24oYSl7cmV0dXJuIHRoaXMucHVzaFN0YWNrKFQodGhpcyxhLCExKSwibm90IixhKX0s
ZmlsdGVyOmZ1bmN0aW9uKGEpe3JldHVybiB0aGlzLnB1c2hTdGFjayhUKHRoaXMsYSwhMCksImZp
bHRlciIsYSl9LGlzOmZ1bmN0aW9uKGEpe3JldHVybiEhYSYmKHR5cGVvZiBhPT0ic3RyaW5nIj9R
LnRlc3QoYSk/ZihhLHRoaXMuY29udGV4dCkuaW5kZXgodGhpc1swXSk+PTA6Zi5maWx0ZXIoYSx0
aGlzKS5sZW5ndGg+MDp0aGlzLmZpbHRlcihhKS5sZW5ndGg+MCl9LGNsb3Nlc3Q6ZnVuY3Rpb24o
YSxiKXt2YXIgYz1bXSxkLGUsZz10aGlzWzBdO2lmKGYuaXNBcnJheShhKSl7dmFyIGg9MTt3aGls
ZShnJiZnLm93bmVyRG9jdW1lbnQmJmchPT1iKXtmb3IoZD0wO2Q8YS5sZW5ndGg7ZCsrKWYoZyku
aXMoYVtkXSkmJmMucHVzaCh7c2VsZWN0b3I6YVtkXSxlbGVtOmcsbGV2ZWw6aH0pO2c9Zy5wYXJl
bnROb2RlLGgrK31yZXR1cm4gY312YXIgaT1RLnRlc3QoYSl8fHR5cGVvZiBhIT0ic3RyaW5nIj9m
KGEsYnx8dGhpcy5jb250ZXh0KTowO2ZvcihkPTAsZT10aGlzLmxlbmd0aDtkPGU7ZCsrKXtnPXRo
aXNbZF07d2hpbGUoZyl7aWYoaT9pLmluZGV4KGcpPi0xOmYuZmluZC5tYXRjaGVzU2VsZWN0b3Io
ZyxhKSl7Yy5wdXNoKGcpO2JyZWFrfWc9Zy5wYXJlbnROb2RlO2lmKCFnfHwhZy5vd25lckRvY3Vt
ZW50fHxnPT09Ynx8Zy5ub2RlVHlwZT09PTExKWJyZWFrfX1jPWMubGVuZ3RoPjE/Zi51bmlxdWUo
Yyk6YztyZXR1cm4gdGhpcy5wdXNoU3RhY2soYywiY2xvc2VzdCIsYSl9LGluZGV4OmZ1bmN0aW9u
KGEpe2lmKCFhKXJldHVybiB0aGlzWzBdJiZ0aGlzWzBdLnBhcmVudE5vZGU/dGhpcy5wcmV2QWxs
KCkubGVuZ3RoOi0xO2lmKHR5cGVvZiBhPT0ic3RyaW5nIilyZXR1cm4gZi5pbkFycmF5KHRoaXNb
MF0sZihhKSk7cmV0dXJuIGYuaW5BcnJheShhLmpxdWVyeT9hWzBdOmEsdGhpcyl9LGFkZDpmdW5j
dGlvbihhLGIpe3ZhciBjPXR5cGVvZiBhPT0ic3RyaW5nIj9mKGEsYik6Zi5tYWtlQXJyYXkoYSYm
YS5ub2RlVHlwZT9bYV06YSksZD1mLm1lcmdlKHRoaXMuZ2V0KCksYyk7cmV0dXJuIHRoaXMucHVz
aFN0YWNrKFMoY1swXSl8fFMoZFswXSk/ZDpmLnVuaXF1ZShkKSl9LGFuZFNlbGY6ZnVuY3Rpb24o
KXtyZXR1cm4gdGhpcy5hZGQodGhpcy5wcmV2T2JqZWN0KX19KSxmLmVhY2goe3BhcmVudDpmdW5j
dGlvbihhKXt2YXIgYj1hLnBhcmVudE5vZGU7cmV0dXJuIGImJmIubm9kZVR5cGUhPT0xMT9iOm51
bGx9LHBhcmVudHM6ZnVuY3Rpb24oYSl7cmV0dXJuIGYuZGlyKGEsInBhcmVudE5vZGUiKX0scGFy
ZW50c1VudGlsOmZ1bmN0aW9uKGEsYixjKXtyZXR1cm4gZi5kaXIoYSwicGFyZW50Tm9kZSIsYyl9
LG5leHQ6ZnVuY3Rpb24oYSl7cmV0dXJuIGYubnRoKGEsMiwibmV4dFNpYmxpbmciKX0scHJldjpm
dW5jdGlvbihhKXtyZXR1cm4gZi5udGgoYSwyLCJwcmV2aW91c1NpYmxpbmciKX0sbmV4dEFsbDpm
dW5jdGlvbihhKXtyZXR1cm4gZi5kaXIoYSwibmV4dFNpYmxpbmciKX0scHJldkFsbDpmdW5jdGlv
bihhKXtyZXR1cm4gZi5kaXIoYSwicHJldmlvdXNTaWJsaW5nIil9LG5leHRVbnRpbDpmdW5jdGlv
bihhLGIsYyl7cmV0dXJuIGYuZGlyKGEsIm5leHRTaWJsaW5nIixjKX0scHJldlVudGlsOmZ1bmN0
aW9uKGEsYixjKXtyZXR1cm4gZi5kaXIoYSwicHJldmlvdXNTaWJsaW5nIixjKX0sc2libGluZ3M6
ZnVuY3Rpb24oYSl7cmV0dXJuIGYuc2libGluZygoYS5wYXJlbnROb2RlfHx7fSkuZmlyc3RDaGls
ZCxhKX0sY2hpbGRyZW46ZnVuY3Rpb24oYSl7cmV0dXJuIGYuc2libGluZyhhLmZpcnN0Q2hpbGQp
fSxjb250ZW50czpmdW5jdGlvbihhKXtyZXR1cm4gZi5ub2RlTmFtZShhLCJpZnJhbWUiKT9hLmNv
bnRlbnREb2N1bWVudHx8YS5jb250ZW50V2luZG93LmRvY3VtZW50OmYubWFrZUFycmF5KGEuY2hp
bGROb2Rlcyl9fSxmdW5jdGlvbihhLGIpe2YuZm5bYV09ZnVuY3Rpb24oYyxkKXt2YXIgZT1mLm1h
cCh0aGlzLGIsYyk7TC50ZXN0KGEpfHwoZD1jKSxkJiZ0eXBlb2YgZD09InN0cmluZyImJihlPWYu
ZmlsdGVyKGQsZSkpLGU9dGhpcy5sZW5ndGg+MSYmIVJbYV0/Zi51bmlxdWUoZSk6ZSwodGhpcy5s
ZW5ndGg+MXx8Ti50ZXN0KGQpKSYmTS50ZXN0KGEpJiYoZT1lLnJldmVyc2UoKSk7cmV0dXJuIHRo
aXMucHVzaFN0YWNrKGUsYSxQLmNhbGwoYXJndW1lbnRzKS5qb2luKCIsIikpfX0pLGYuZXh0ZW5k
KHtmaWx0ZXI6ZnVuY3Rpb24oYSxiLGMpe2MmJihhPSI6bm90KCIrYSsiKSIpO3JldHVybiBiLmxl
bmd0aD09PTE/Zi5maW5kLm1hdGNoZXNTZWxlY3RvcihiWzBdLGEpP1tiWzBdXTpbXTpmLmZpbmQu
bWF0Y2hlcyhhLGIpfSxkaXI6ZnVuY3Rpb24oYSxjLGQpe3ZhciBlPVtdLGc9YVtjXTt3aGlsZShn
JiZnLm5vZGVUeXBlIT09OSYmKGQ9PT1ifHxnLm5vZGVUeXBlIT09MXx8IWYoZykuaXMoZCkpKWcu
bm9kZVR5cGU9PT0xJiZlLnB1c2goZyksZz1nW2NdO3JldHVybiBlfSxudGg6ZnVuY3Rpb24oYSxi
LGMsZCl7Yj1ifHwxO3ZhciBlPTA7Zm9yKDthO2E9YVtjXSlpZihhLm5vZGVUeXBlPT09MSYmKytl
PT09YilicmVhaztyZXR1cm4gYX0sc2libGluZzpmdW5jdGlvbihhLGIpe3ZhciBjPVtdO2Zvcig7
YTthPWEubmV4dFNpYmxpbmcpYS5ub2RlVHlwZT09PTEmJmEhPT1iJiZjLnB1c2goYSk7cmV0dXJu
IGN9fSk7dmFyIFY9ImFiYnJ8YXJ0aWNsZXxhc2lkZXxhdWRpb3xiZGl8Y2FudmFzfGRhdGF8ZGF0
YWxpc3R8ZGV0YWlsc3xmaWdjYXB0aW9ufGZpZ3VyZXxmb290ZXJ8aGVhZGVyfGhncm91cHxtYXJr
fG1ldGVyfG5hdnxvdXRwdXR8cHJvZ3Jlc3N8c2VjdGlvbnxzdW1tYXJ5fHRpbWV8dmlkZW8iLFc9
LyBqUXVlcnlcZCs9Iig/OlxkK3xudWxsKSIvZyxYPS9eXHMrLyxZPS88KD8hYXJlYXxicnxjb2x8
ZW1iZWR8aHJ8aW1nfGlucHV0fGxpbmt8bWV0YXxwYXJhbSkoKFtcdzpdKylbXj5dKilcLz4vaWcs
Wj0vPChbXHc6XSspLywkPS88dGJvZHkvaSxfPS88fCYjP1x3KzsvLGJhPS88KD86c2NyaXB0fHN0
eWxlKS9pLGJiPS88KD86c2NyaXB0fG9iamVjdHxlbWJlZHxvcHRpb258c3R5bGUpL2ksYmM9bmV3
IFJlZ0V4cCgiPCg/OiIrVisiKVtcXHMvPl0iLCJpIiksYmQ9L2NoZWNrZWRccyooPzpbXj1dfD1c
cyouY2hlY2tlZC4pL2ksYmU9L1wvKGphdmF8ZWNtYSlzY3JpcHQvaSxiZj0vXlxzKjwhKD86XFtD
REFUQVxbfFwtXC0pLyxiZz17b3B0aW9uOlsxLCI8c2VsZWN0IG11bHRpcGxlPSdtdWx0aXBsZSc+
IiwiPC9zZWxlY3Q+Il0sbGVnZW5kOlsxLCI8ZmllbGRzZXQ+IiwiPC9maWVsZHNldD4iXSx0aGVh
ZDpbMSwiPHRhYmxlPiIsIjwvdGFibGU+Il0sdHI6WzIsIjx0YWJsZT48dGJvZHk+IiwiPC90Ym9k
eT48L3RhYmxlPiJdLHRkOlszLCI8dGFibGU+PHRib2R5Pjx0cj4iLCI8L3RyPjwvdGJvZHk+PC90
YWJsZT4iXSxjb2w6WzIsIjx0YWJsZT48dGJvZHk+PC90Ym9keT48Y29sZ3JvdXA+IiwiPC9jb2xn
cm91cD48L3RhYmxlPiJdLGFyZWE6WzEsIjxtYXA+IiwiPC9tYXA+Il0sX2RlZmF1bHQ6WzAsIiIs
IiJdfSxiaD1VKGMpO2JnLm9wdGdyb3VwPWJnLm9wdGlvbixiZy50Ym9keT1iZy50Zm9vdD1iZy5j
b2xncm91cD1iZy5jYXB0aW9uPWJnLnRoZWFkLGJnLnRoPWJnLnRkLGYuc3VwcG9ydC5odG1sU2Vy
aWFsaXplfHwoYmcuX2RlZmF1bHQ9WzEsImRpdjxkaXY+IiwiPC9kaXY+Il0pLGYuZm4uZXh0ZW5k
KHt0ZXh0OmZ1bmN0aW9uKGEpe3JldHVybiBmLmFjY2Vzcyh0aGlzLGZ1bmN0aW9uKGEpe3JldHVy
biBhPT09Yj9mLnRleHQodGhpcyk6dGhpcy5lbXB0eSgpLmFwcGVuZCgodGhpc1swXSYmdGhpc1sw
XS5vd25lckRvY3VtZW50fHxjKS5jcmVhdGVUZXh0Tm9kZShhKSl9LG51bGwsYSxhcmd1bWVudHMu
bGVuZ3RoKX0sd3JhcEFsbDpmdW5jdGlvbihhKXtpZihmLmlzRnVuY3Rpb24oYSkpcmV0dXJuIHRo
aXMuZWFjaChmdW5jdGlvbihiKXtmKHRoaXMpLndyYXBBbGwoYS5jYWxsKHRoaXMsYikpfSk7aWYo
dGhpc1swXSl7dmFyIGI9ZihhLHRoaXNbMF0ub3duZXJEb2N1bWVudCkuZXEoMCkuY2xvbmUoITAp
O3RoaXNbMF0ucGFyZW50Tm9kZSYmYi5pbnNlcnRCZWZvcmUodGhpc1swXSksYi5tYXAoZnVuY3Rp
b24oKXt2YXIgYT10aGlzO3doaWxlKGEuZmlyc3RDaGlsZCYmYS5maXJzdENoaWxkLm5vZGVUeXBl
PT09MSlhPWEuZmlyc3RDaGlsZDtyZXR1cm4gYX0pLmFwcGVuZCh0aGlzKX1yZXR1cm4gdGhpc30s
d3JhcElubmVyOmZ1bmN0aW9uKGEpe2lmKGYuaXNGdW5jdGlvbihhKSlyZXR1cm4gdGhpcy5lYWNo
KGZ1bmN0aW9uKGIpe2YodGhpcykud3JhcElubmVyKGEuY2FsbCh0aGlzLGIpKX0pO3JldHVybiB0
aGlzLmVhY2goZnVuY3Rpb24oKXt2YXIgYj1mKHRoaXMpLGM9Yi5jb250ZW50cygpO2MubGVuZ3Ro
P2Mud3JhcEFsbChhKTpiLmFwcGVuZChhKX0pfSx3cmFwOmZ1bmN0aW9uKGEpe3ZhciBiPWYuaXNG
dW5jdGlvbihhKTtyZXR1cm4gdGhpcy5lYWNoKGZ1bmN0aW9uKGMpe2YodGhpcykud3JhcEFsbChi
P2EuY2FsbCh0aGlzLGMpOmEpfSl9LHVud3JhcDpmdW5jdGlvbigpe3JldHVybiB0aGlzLnBhcmVu
dCgpLmVhY2goZnVuY3Rpb24oKXtmLm5vZGVOYW1lKHRoaXMsImJvZHkiKXx8Zih0aGlzKS5yZXBs
YWNlV2l0aCh0aGlzLmNoaWxkTm9kZXMpfSkuZW5kKCl9LGFwcGVuZDpmdW5jdGlvbigpe3JldHVy
biB0aGlzLmRvbU1hbmlwKGFyZ3VtZW50cywhMCxmdW5jdGlvbihhKXt0aGlzLm5vZGVUeXBlPT09
MSYmdGhpcy5hcHBlbmRDaGlsZChhKX0pfSxwcmVwZW5kOmZ1bmN0aW9uKCl7cmV0dXJuIHRoaXMu
ZG9tTWFuaXAoYXJndW1lbnRzLCEwLGZ1bmN0aW9uKGEpe3RoaXMubm9kZVR5cGU9PT0xJiZ0aGlz
Lmluc2VydEJlZm9yZShhLHRoaXMuZmlyc3RDaGlsZCl9KX0sYmVmb3JlOmZ1bmN0aW9uKCl7aWYo
dGhpc1swXSYmdGhpc1swXS5wYXJlbnROb2RlKXJldHVybiB0aGlzLmRvbU1hbmlwKGFyZ3VtZW50
cywhMSxmdW5jdGlvbihhKXt0aGlzLnBhcmVudE5vZGUuaW5zZXJ0QmVmb3JlKGEsdGhpcyl9KTtp
Zihhcmd1bWVudHMubGVuZ3RoKXt2YXIgYT1mCi5jbGVhbihhcmd1bWVudHMpO2EucHVzaC5hcHBs
eShhLHRoaXMudG9BcnJheSgpKTtyZXR1cm4gdGhpcy5wdXNoU3RhY2soYSwiYmVmb3JlIixhcmd1
bWVudHMpfX0sYWZ0ZXI6ZnVuY3Rpb24oKXtpZih0aGlzWzBdJiZ0aGlzWzBdLnBhcmVudE5vZGUp
cmV0dXJuIHRoaXMuZG9tTWFuaXAoYXJndW1lbnRzLCExLGZ1bmN0aW9uKGEpe3RoaXMucGFyZW50
Tm9kZS5pbnNlcnRCZWZvcmUoYSx0aGlzLm5leHRTaWJsaW5nKX0pO2lmKGFyZ3VtZW50cy5sZW5n
dGgpe3ZhciBhPXRoaXMucHVzaFN0YWNrKHRoaXMsImFmdGVyIixhcmd1bWVudHMpO2EucHVzaC5h
cHBseShhLGYuY2xlYW4oYXJndW1lbnRzKSk7cmV0dXJuIGF9fSxyZW1vdmU6ZnVuY3Rpb24oYSxi
KXtmb3IodmFyIGM9MCxkOyhkPXRoaXNbY10pIT1udWxsO2MrKylpZighYXx8Zi5maWx0ZXIoYSxb
ZF0pLmxlbmd0aCkhYiYmZC5ub2RlVHlwZT09PTEmJihmLmNsZWFuRGF0YShkLmdldEVsZW1lbnRz
QnlUYWdOYW1lKCIqIikpLGYuY2xlYW5EYXRhKFtkXSkpLGQucGFyZW50Tm9kZSYmZC5wYXJlbnRO
b2RlLnJlbW92ZUNoaWxkKGQpO3JldHVybiB0aGlzfSxlbXB0eTpmdW5jdGlvbigpe2Zvcih2YXIg
YT0wLGI7KGI9dGhpc1thXSkhPW51bGw7YSsrKXtiLm5vZGVUeXBlPT09MSYmZi5jbGVhbkRhdGEo
Yi5nZXRFbGVtZW50c0J5VGFnTmFtZSgiKiIpKTt3aGlsZShiLmZpcnN0Q2hpbGQpYi5yZW1vdmVD
aGlsZChiLmZpcnN0Q2hpbGQpfXJldHVybiB0aGlzfSxjbG9uZTpmdW5jdGlvbihhLGIpe2E9YT09
bnVsbD8hMTphLGI9Yj09bnVsbD9hOmI7cmV0dXJuIHRoaXMubWFwKGZ1bmN0aW9uKCl7cmV0dXJu
IGYuY2xvbmUodGhpcyxhLGIpfSl9LGh0bWw6ZnVuY3Rpb24oYSl7cmV0dXJuIGYuYWNjZXNzKHRo
aXMsZnVuY3Rpb24oYSl7dmFyIGM9dGhpc1swXXx8e30sZD0wLGU9dGhpcy5sZW5ndGg7aWYoYT09
PWIpcmV0dXJuIGMubm9kZVR5cGU9PT0xP2MuaW5uZXJIVE1MLnJlcGxhY2UoVywiIik6bnVsbDtp
Zih0eXBlb2YgYT09InN0cmluZyImJiFiYS50ZXN0KGEpJiYoZi5zdXBwb3J0LmxlYWRpbmdXaGl0
ZXNwYWNlfHwhWC50ZXN0KGEpKSYmIWJnWyhaLmV4ZWMoYSl8fFsiIiwiIl0pWzFdLnRvTG93ZXJD
YXNlKCldKXthPWEucmVwbGFjZShZLCI8JDE+PC8kMj4iKTt0cnl7Zm9yKDtkPGU7ZCsrKWM9dGhp
c1tkXXx8e30sYy5ub2RlVHlwZT09PTEmJihmLmNsZWFuRGF0YShjLmdldEVsZW1lbnRzQnlUYWdO
YW1lKCIqIikpLGMuaW5uZXJIVE1MPWEpO2M9MH1jYXRjaChnKXt9fWMmJnRoaXMuZW1wdHkoKS5h
cHBlbmQoYSl9LG51bGwsYSxhcmd1bWVudHMubGVuZ3RoKX0scmVwbGFjZVdpdGg6ZnVuY3Rpb24o
YSl7aWYodGhpc1swXSYmdGhpc1swXS5wYXJlbnROb2RlKXtpZihmLmlzRnVuY3Rpb24oYSkpcmV0
dXJuIHRoaXMuZWFjaChmdW5jdGlvbihiKXt2YXIgYz1mKHRoaXMpLGQ9Yy5odG1sKCk7Yy5yZXBs
YWNlV2l0aChhLmNhbGwodGhpcyxiLGQpKX0pO3R5cGVvZiBhIT0ic3RyaW5nIiYmKGE9ZihhKS5k
ZXRhY2goKSk7cmV0dXJuIHRoaXMuZWFjaChmdW5jdGlvbigpe3ZhciBiPXRoaXMubmV4dFNpYmxp
bmcsYz10aGlzLnBhcmVudE5vZGU7Zih0aGlzKS5yZW1vdmUoKSxiP2YoYikuYmVmb3JlKGEpOmYo
YykuYXBwZW5kKGEpfSl9cmV0dXJuIHRoaXMubGVuZ3RoP3RoaXMucHVzaFN0YWNrKGYoZi5pc0Z1
bmN0aW9uKGEpP2EoKTphKSwicmVwbGFjZVdpdGgiLGEpOnRoaXN9LGRldGFjaDpmdW5jdGlvbihh
KXtyZXR1cm4gdGhpcy5yZW1vdmUoYSwhMCl9LGRvbU1hbmlwOmZ1bmN0aW9uKGEsYyxkKXt2YXIg
ZSxnLGgsaSxqPWFbMF0saz1bXTtpZighZi5zdXBwb3J0LmNoZWNrQ2xvbmUmJmFyZ3VtZW50cy5s
ZW5ndGg9PT0zJiZ0eXBlb2Ygaj09InN0cmluZyImJmJkLnRlc3QoaikpcmV0dXJuIHRoaXMuZWFj
aChmdW5jdGlvbigpe2YodGhpcykuZG9tTWFuaXAoYSxjLGQsITApfSk7aWYoZi5pc0Z1bmN0aW9u
KGopKXJldHVybiB0aGlzLmVhY2goZnVuY3Rpb24oZSl7dmFyIGc9Zih0aGlzKTthWzBdPWouY2Fs
bCh0aGlzLGUsYz9nLmh0bWwoKTpiKSxnLmRvbU1hbmlwKGEsYyxkKX0pO2lmKHRoaXNbMF0pe2k9
aiYmai5wYXJlbnROb2RlLGYuc3VwcG9ydC5wYXJlbnROb2RlJiZpJiZpLm5vZGVUeXBlPT09MTEm
JmkuY2hpbGROb2Rlcy5sZW5ndGg9PT10aGlzLmxlbmd0aD9lPXtmcmFnbWVudDppfTplPWYuYnVp
bGRGcmFnbWVudChhLHRoaXMsayksaD1lLmZyYWdtZW50LGguY2hpbGROb2Rlcy5sZW5ndGg9PT0x
P2c9aD1oLmZpcnN0Q2hpbGQ6Zz1oLmZpcnN0Q2hpbGQ7aWYoZyl7Yz1jJiZmLm5vZGVOYW1lKGcs
InRyIik7Zm9yKHZhciBsPTAsbT10aGlzLmxlbmd0aCxuPW0tMTtsPG07bCsrKWQuY2FsbChjP2Jp
KHRoaXNbbF0sZyk6dGhpc1tsXSxlLmNhY2hlYWJsZXx8bT4xJiZsPG4/Zi5jbG9uZShoLCEwLCEw
KTpoKX1rLmxlbmd0aCYmZi5lYWNoKGssZnVuY3Rpb24oYSxiKXtiLnNyYz9mLmFqYXgoe3R5cGU6
IkdFVCIsZ2xvYmFsOiExLHVybDpiLnNyYyxhc3luYzohMSxkYXRhVHlwZToic2NyaXB0In0pOmYu
Z2xvYmFsRXZhbCgoYi50ZXh0fHxiLnRleHRDb250ZW50fHxiLmlubmVySFRNTHx8IiIpLnJlcGxh
Y2UoYmYsIi8qJDAqLyIpKSxiLnBhcmVudE5vZGUmJmIucGFyZW50Tm9kZS5yZW1vdmVDaGlsZChi
KX0pfXJldHVybiB0aGlzfX0pLGYuYnVpbGRGcmFnbWVudD1mdW5jdGlvbihhLGIsZCl7dmFyIGUs
ZyxoLGksaj1hWzBdO2ImJmJbMF0mJihpPWJbMF0ub3duZXJEb2N1bWVudHx8YlswXSksaS5jcmVh
dGVEb2N1bWVudEZyYWdtZW50fHwoaT1jKSxhLmxlbmd0aD09PTEmJnR5cGVvZiBqPT0ic3RyaW5n
IiYmai5sZW5ndGg8NTEyJiZpPT09YyYmai5jaGFyQXQoMCk9PT0iPCImJiFiYi50ZXN0KGopJiYo
Zi5zdXBwb3J0LmNoZWNrQ2xvbmV8fCFiZC50ZXN0KGopKSYmKGYuc3VwcG9ydC5odG1sNUNsb25l
fHwhYmMudGVzdChqKSkmJihnPSEwLGg9Zi5mcmFnbWVudHNbal0saCYmaCE9PTEmJihlPWgpKSxl
fHwoZT1pLmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKSxmLmNsZWFuKGEsaSxlLGQpKSxnJiYoZi5m
cmFnbWVudHNbal09aD9lOjEpO3JldHVybntmcmFnbWVudDplLGNhY2hlYWJsZTpnfX0sZi5mcmFn
bWVudHM9e30sZi5lYWNoKHthcHBlbmRUbzoiYXBwZW5kIixwcmVwZW5kVG86InByZXBlbmQiLGlu
c2VydEJlZm9yZToiYmVmb3JlIixpbnNlcnRBZnRlcjoiYWZ0ZXIiLHJlcGxhY2VBbGw6InJlcGxh
Y2VXaXRoIn0sZnVuY3Rpb24oYSxiKXtmLmZuW2FdPWZ1bmN0aW9uKGMpe3ZhciBkPVtdLGU9Zihj
KSxnPXRoaXMubGVuZ3RoPT09MSYmdGhpc1swXS5wYXJlbnROb2RlO2lmKGcmJmcubm9kZVR5cGU9
PT0xMSYmZy5jaGlsZE5vZGVzLmxlbmd0aD09PTEmJmUubGVuZ3RoPT09MSl7ZVtiXSh0aGlzWzBd
KTtyZXR1cm4gdGhpc31mb3IodmFyIGg9MCxpPWUubGVuZ3RoO2g8aTtoKyspe3ZhciBqPShoPjA/
dGhpcy5jbG9uZSghMCk6dGhpcykuZ2V0KCk7ZihlW2hdKVtiXShqKSxkPWQuY29uY2F0KGopfXJl
dHVybiB0aGlzLnB1c2hTdGFjayhkLGEsZS5zZWxlY3Rvcil9fSksZi5leHRlbmQoe2Nsb25lOmZ1
bmN0aW9uKGEsYixjKXt2YXIgZCxlLGcsaD1mLnN1cHBvcnQuaHRtbDVDbG9uZXx8Zi5pc1hNTERv
YyhhKXx8IWJjLnRlc3QoIjwiK2Eubm9kZU5hbWUrIj4iKT9hLmNsb25lTm9kZSghMCk6Ym8oYSk7
aWYoKCFmLnN1cHBvcnQubm9DbG9uZUV2ZW50fHwhZi5zdXBwb3J0Lm5vQ2xvbmVDaGVja2VkKSYm
KGEubm9kZVR5cGU9PT0xfHxhLm5vZGVUeXBlPT09MTEpJiYhZi5pc1hNTERvYyhhKSl7YmsoYSxo
KSxkPWJsKGEpLGU9YmwoaCk7Zm9yKGc9MDtkW2ddOysrZyllW2ddJiZiayhkW2ddLGVbZ10pfWlm
KGIpe2JqKGEsaCk7aWYoYyl7ZD1ibChhKSxlPWJsKGgpO2ZvcihnPTA7ZFtnXTsrK2cpYmooZFtn
XSxlW2ddKX19ZD1lPW51bGw7cmV0dXJuIGh9LGNsZWFuOmZ1bmN0aW9uKGEsYixkLGUpe3ZhciBn
LGgsaSxqPVtdO2I9Ynx8Yyx0eXBlb2YgYi5jcmVhdGVFbGVtZW50PT0idW5kZWZpbmVkIiYmKGI9
Yi5vd25lckRvY3VtZW50fHxiWzBdJiZiWzBdLm93bmVyRG9jdW1lbnR8fGMpO2Zvcih2YXIgaz0w
LGw7KGw9YVtrXSkhPW51bGw7aysrKXt0eXBlb2YgbD09Im51bWJlciImJihsKz0iIik7aWYoIWwp
Y29udGludWU7aWYodHlwZW9mIGw9PSJzdHJpbmciKWlmKCFfLnRlc3QobCkpbD1iLmNyZWF0ZVRl
eHROb2RlKGwpO2Vsc2V7bD1sLnJlcGxhY2UoWSwiPCQxPjwvJDI+Iik7dmFyIG09KFouZXhlYyhs
KXx8WyIiLCIiXSlbMV0udG9Mb3dlckNhc2UoKSxuPWJnW21dfHxiZy5fZGVmYXVsdCxvPW5bMF0s
cD1iLmNyZWF0ZUVsZW1lbnQoImRpdiIpLHE9YmguY2hpbGROb2RlcyxyO2I9PT1jP2JoLmFwcGVu
ZENoaWxkKHApOlUoYikuYXBwZW5kQ2hpbGQocCkscC5pbm5lckhUTUw9blsxXStsK25bMl07d2hp
bGUoby0tKXA9cC5sYXN0Q2hpbGQ7aWYoIWYuc3VwcG9ydC50Ym9keSl7dmFyIHM9JC50ZXN0KGwp
LHQ9bT09PSJ0YWJsZSImJiFzP3AuZmlyc3RDaGlsZCYmcC5maXJzdENoaWxkLmNoaWxkTm9kZXM6
blsxXT09PSI8dGFibGU+IiYmIXM/cC5jaGlsZE5vZGVzOltdO2ZvcihpPXQubGVuZ3RoLTE7aT49
MDstLWkpZi5ub2RlTmFtZSh0W2ldLCJ0Ym9keSIpJiYhdFtpXS5jaGlsZE5vZGVzLmxlbmd0aCYm
dFtpXS5wYXJlbnROb2RlLnJlbW92ZUNoaWxkKHRbaV0pfSFmLnN1cHBvcnQubGVhZGluZ1doaXRl
c3BhY2UmJlgudGVzdChsKSYmcC5pbnNlcnRCZWZvcmUoYi5jcmVhdGVUZXh0Tm9kZShYLmV4ZWMo
bClbMF0pLHAuZmlyc3RDaGlsZCksbD1wLmNoaWxkTm9kZXMscCYmKHAucGFyZW50Tm9kZS5yZW1v
dmVDaGlsZChwKSxxLmxlbmd0aD4wJiYocj1xW3EubGVuZ3RoLTFdLHImJnIucGFyZW50Tm9kZSYm
ci5wYXJlbnROb2RlLnJlbW92ZUNoaWxkKHIpKSl9dmFyIHU7aWYoIWYuc3VwcG9ydC5hcHBlbmRD
aGVja2VkKWlmKGxbMF0mJnR5cGVvZiAodT1sLmxlbmd0aCk9PSJudW1iZXIiKWZvcihpPTA7aTx1
O2krKylibihsW2ldKTtlbHNlIGJuKGwpO2wubm9kZVR5cGU/ai5wdXNoKGwpOmo9Zi5tZXJnZShq
LGwpfWlmKGQpe2c9ZnVuY3Rpb24oYSl7cmV0dXJuIWEudHlwZXx8YmUudGVzdChhLnR5cGUpfTtm
b3Ioaz0wO2pba107aysrKXtoPWpba107aWYoZSYmZi5ub2RlTmFtZShoLCJzY3JpcHQiKSYmKCFo
LnR5cGV8fGJlLnRlc3QoaC50eXBlKSkpZS5wdXNoKGgucGFyZW50Tm9kZT9oLnBhcmVudE5vZGUu
cmVtb3ZlQ2hpbGQoaCk6aCk7ZWxzZXtpZihoLm5vZGVUeXBlPT09MSl7dmFyIHY9Zi5ncmVwKGgu
Z2V0RWxlbWVudHNCeVRhZ05hbWUoInNjcmlwdCIpLGcpO2ouc3BsaWNlLmFwcGx5KGosW2srMSww
XS5jb25jYXQodikpfWQuYXBwZW5kQ2hpbGQoaCl9fX1yZXR1cm4gan0sY2xlYW5EYXRhOmZ1bmN0
aW9uKGEpe3ZhciBiLGMsZD1mLmNhY2hlLGU9Zi5ldmVudC5zcGVjaWFsLGc9Zi5zdXBwb3J0LmRl
bGV0ZUV4cGFuZG87Zm9yKHZhciBoPTAsaTsoaT1hW2hdKSE9bnVsbDtoKyspe2lmKGkubm9kZU5h
bWUmJmYubm9EYXRhW2kubm9kZU5hbWUudG9Mb3dlckNhc2UoKV0pY29udGludWU7Yz1pW2YuZXhw
YW5kb107aWYoYyl7Yj1kW2NdO2lmKGImJmIuZXZlbnRzKXtmb3IodmFyIGogaW4gYi5ldmVudHMp
ZVtqXT9mLmV2ZW50LnJlbW92ZShpLGopOmYucmVtb3ZlRXZlbnQoaSxqLGIuaGFuZGxlKTtiLmhh
bmRsZSYmKGIuaGFuZGxlLmVsZW09bnVsbCl9Zz9kZWxldGUgaVtmLmV4cGFuZG9dOmkucmVtb3Zl
QXR0cmlidXRlJiZpLnJlbW92ZUF0dHJpYnV0ZShmLmV4cGFuZG8pLGRlbGV0ZSBkW2NdfX19fSk7
dmFyIGJwPS9hbHBoYVwoW14pXSpcKS9pLGJxPS9vcGFjaXR5PShbXildKikvLGJyPS8oW0EtWl18
Xm1zKS9nLGJzPS9eW1wtK10/KD86XGQqXC4pP1xkKyQvaSxidD0vXi0/KD86XGQqXC4pP1xkKyg/
IXB4KVteXGRcc10rJC9pLGJ1PS9eKFtcLStdKT0oW1wtKy5cZGVdKykvLGJ2PS9ebWFyZ2luLyxi
dz17cG9zaXRpb246ImFic29sdXRlIix2aXNpYmlsaXR5OiJoaWRkZW4iLGRpc3BsYXk6ImJsb2Nr
In0sYng9WyJUb3AiLCJSaWdodCIsIkJvdHRvbSIsIkxlZnQiXSxieSxieixiQTtmLmZuLmNzcz1m
dW5jdGlvbihhLGMpe3JldHVybiBmLmFjY2Vzcyh0aGlzLGZ1bmN0aW9uKGEsYyxkKXtyZXR1cm4g
ZCE9PWI/Zi5zdHlsZShhLGMsZCk6Zi5jc3MoYSxjKX0sYSxjLGFyZ3VtZW50cy5sZW5ndGg+MSl9
LGYuZXh0ZW5kKHtjc3NIb29rczp7b3BhY2l0eTp7Z2V0OmZ1bmN0aW9uKGEsYil7aWYoYil7dmFy
IGM9YnkoYSwib3BhY2l0eSIpO3JldHVybiBjPT09IiI/IjEiOmN9cmV0dXJuIGEuc3R5bGUub3Bh
Y2l0eX19fSxjc3NOdW1iZXI6e2ZpbGxPcGFjaXR5OiEwLGZvbnRXZWlnaHQ6ITAsbGluZUhlaWdo
dDohMCxvcGFjaXR5OiEwLG9ycGhhbnM6ITAsd2lkb3dzOiEwLHpJbmRleDohMCx6b29tOiEwfSxj
c3NQcm9wczp7ImZsb2F0IjpmLnN1cHBvcnQuY3NzRmxvYXQ/ImNzc0Zsb2F0Ijoic3R5bGVGbG9h
dCJ9LHN0eWxlOmZ1bmN0aW9uKGEsYyxkLGUpe2lmKCEhYSYmYS5ub2RlVHlwZSE9PTMmJmEubm9k
ZVR5cGUhPT04JiYhIWEuc3R5bGUpe3ZhciBnLGgsaT1mLmNhbWVsQ2FzZShjKSxqPWEuc3R5bGUs
az1mLmNzc0hvb2tzW2ldO2M9Zi5jc3NQcm9wc1tpXXx8aTtpZihkPT09Yil7aWYoayYmImdldCJp
biBrJiYoZz1rLmdldChhLCExLGUpKSE9PWIpcmV0dXJuIGc7cmV0dXJuIGpbY119aD10eXBlb2Yg
ZCxoPT09InN0cmluZyImJihnPWJ1LmV4ZWMoZCkpJiYoZD0rKGdbMV0rMSkqK2dbMl0rcGFyc2VG
bG9hdChmLmNzcyhhLGMpKSxoPSJudW1iZXIiKTtpZihkPT1udWxsfHxoPT09Im51bWJlciImJmlz
TmFOKGQpKXJldHVybjtoPT09Im51bWJlciImJiFmLmNzc051bWJlcltpXSYmKGQrPSJweCIpO2lm
KCFrfHwhKCJzZXQiaW4gayl8fChkPWsuc2V0KGEsZCkpIT09Yil0cnl7altjXT1kfWNhdGNoKGwp
e319fSxjc3M6ZnVuY3Rpb24oYSxjLGQpe3ZhciBlLGc7Yz1mLmNhbWVsQ2FzZShjKSxnPWYuY3Nz
SG9va3NbY10sYz1mLmNzc1Byb3BzW2NdfHxjLGM9PT0iY3NzRmxvYXQiJiYoYz0iZmxvYXQiKTtp
ZihnJiYiZ2V0ImluIGcmJihlPWcuZ2V0KGEsITAsZCkpIT09YilyZXR1cm4gZTtpZihieSlyZXR1
cm4gYnkoYSxjKX0sc3dhcDpmdW5jdGlvbihhLGIsYyl7dmFyIGQ9e30sZSxmO2ZvcihmIGluIGIp
ZFtmXT1hLnN0eWxlW2ZdLGEuc3R5bGVbZl09YltmXTtlPWMuY2FsbChhKTtmb3IoZiBpbiBiKWEu
c3R5bGVbZl09ZFtmXTtyZXR1cm4gZX19KSxmLmN1ckNTUz1mLmNzcyxjLmRlZmF1bHRWaWV3JiZj
LmRlZmF1bHRWaWV3LmdldENvbXB1dGVkU3R5bGUmJihiej1mdW5jdGlvbihhLGIpe3ZhciBjLGQs
ZSxnLGg9YS5zdHlsZTtiPWIucmVwbGFjZShiciwiLSQxIikudG9Mb3dlckNhc2UoKSwoZD1hLm93
bmVyRG9jdW1lbnQuZGVmYXVsdFZpZXcpJiYoZT1kLmdldENvbXB1dGVkU3R5bGUoYSxudWxsKSkm
JihjPWUuZ2V0UHJvcGVydHlWYWx1ZShiKSxjPT09IiImJiFmLmNvbnRhaW5zKGEub3duZXJEb2N1
bWVudC5kb2N1bWVudEVsZW1lbnQsYSkmJihjPWYuc3R5bGUoYSxiKSkpLCFmLnN1cHBvcnQucGl4
ZWxNYXJnaW4mJmUmJmJ2LnRlc3QoYikmJmJ0LnRlc3QoYykmJihnPWgud2lkdGgsaC53aWR0aD1j
LGM9ZS53aWR0aCxoLndpZHRoPWcpO3JldHVybiBjfSksYy5kb2N1bWVudEVsZW1lbnQuY3VycmVu
dFN0eWxlJiYoYkE9ZnVuY3Rpb24oYSxiKXt2YXIgYyxkLGUsZj1hLmN1cnJlbnRTdHlsZSYmYS5j
dXJyZW50U3R5bGVbYl0sZz1hLnN0eWxlO2Y9PW51bGwmJmcmJihlPWdbYl0pJiYoZj1lKSxidC50
ZXN0KGYpJiYoYz1nLmxlZnQsZD1hLnJ1bnRpbWVTdHlsZSYmYS5ydW50aW1lU3R5bGUubGVmdCxk
JiYoYS5ydW50aW1lU3R5bGUubGVmdD1hLmN1cnJlbnRTdHlsZS5sZWZ0KSxnLmxlZnQ9Yj09PSJm
b250U2l6ZSI/IjFlbSI6ZixmPWcucGl4ZWxMZWZ0KyJweCIsZy5sZWZ0PWMsZCYmKGEucnVudGlt
ZVN0eWxlLmxlZnQ9ZCkpO3JldHVybiBmPT09IiI/ImF1dG8iOmZ9KSxieT1ienx8YkEsZi5lYWNo
KFsiaGVpZ2h0Iiwid2lkdGgiXSxmdW5jdGlvbihhLGIpe2YuY3NzSG9va3NbYl09e2dldDpmdW5j
dGlvbihhLGMsZCl7aWYoYylyZXR1cm4gYS5vZmZzZXRXaWR0aCE9PTA/YkIoYSxiLGQpOmYuc3dh
cChhLGJ3LGZ1bmN0aW9uKCl7cmV0dXJuIGJCKGEsYixkKX0pfSxzZXQ6ZnVuY3Rpb24oYSxiKXty
ZXR1cm4gYnMudGVzdChiKT9iKyJweCI6Yn19fSksZi5zdXBwb3J0Lm9wYWNpdHl8fChmLmNzc0hv
b2tzLm9wYWNpdHk9e2dldDpmdW5jdGlvbihhLGIpe3JldHVybiBicS50ZXN0KChiJiZhLmN1cnJl
bnRTdHlsZT9hLmN1cnJlbnRTdHlsZS5maWx0ZXI6YS5zdHlsZS5maWx0ZXIpfHwiIik/cGFyc2VG
bG9hdChSZWdFeHAuJDEpLzEwMCsiIjpiPyIxIjoiIn0sc2V0OmZ1bmN0aW9uKGEsYil7dmFyIGM9
YS5zdHlsZSxkPWEuY3VycmVudFN0eWxlLGU9Zi5pc051bWVyaWMoYik/ImFscGhhKG9wYWNpdHk9
IitiKjEwMCsiKSI6IiIsZz1kJiZkLmZpbHRlcnx8Yy5maWx0ZXJ8fCIiO2Muem9vbT0xO2lmKGI+
PTEmJmYudHJpbShnLnJlcGxhY2UoYnAsIiIpKT09PSIiKXtjLnJlbW92ZUF0dHJpYnV0ZSgiZmls
dGVyIik7aWYoZCYmIWQuZmlsdGVyKXJldHVybn1jLmZpbHRlcj1icC50ZXN0KGcpP2cucmVwbGFj
ZShicCxlKTpnKyIgIitlfX0pLGYoZnVuY3Rpb24oKXtmLnN1cHBvcnQucmVsaWFibGVNYXJnaW5S
aWdodHx8KGYuY3NzSG9va3MubWFyZ2luUmlnaHQ9e2dldDpmdW5jdGlvbihhLGIpe3JldHVybiBm
LnN3YXAoYSx7ZGlzcGxheToiaW5saW5lLWJsb2NrIn0sZnVuY3Rpb24oKXtyZXR1cm4gYj9ieShh
LCJtYXJnaW4tcmlnaHQiKTphLnN0eWxlLm1hcmdpblJpZ2h0fSl9fSl9KSxmLmV4cHImJmYuZXhw
ci5maWx0ZXJzJiYoZi5leHByLmZpbHRlcnMuaGlkZGVuPWZ1bmN0aW9uKGEpe3ZhciBiPWEub2Zm
c2V0V2lkdGgsYz1hLm9mZnNldEhlaWdodDtyZXR1cm4gYj09PTAmJmM9PT0wfHwhZi5zdXBwb3J0
LnJlbGlhYmxlSGlkZGVuT2Zmc2V0cyYmKGEuc3R5bGUmJmEuc3R5bGUuZGlzcGxheXx8Zi5jc3Mo
YSwiZGlzcGxheSIpKT09PSJub25lIn0sZi5leHByLmZpbHRlcnMudmlzaWJsZT1mdW5jdGlvbihh
KXtyZXR1cm4hZi5leHByLmZpbHRlcnMuaGlkZGVuKGEpfSksZi5lYWNoKHttYXJnaW46IiIscGFk
ZGluZzoiIixib3JkZXI6IldpZHRoIn0sZnVuY3Rpb24oYSxiKXtmLmNzc0hvb2tzW2ErYl09e2V4
cGFuZDpmdW5jdGlvbihjKXt2YXIgZCxlPXR5cGVvZiBjPT0ic3RyaW5nIj9jLnNwbGl0KCIgIik6
W2NdLGY9e307Zm9yKGQ9MDtkPDQ7ZCsrKWZbYStieFtkXStiXT1lW2RdfHxlW2QtMl18fGVbMF07
cmV0dXJuIGZ9fX0pO3ZhciBiQz0vJTIwL2csYkQ9L1xbXF0kLyxiRT0vXHI/XG4vZyxiRj0vIy4q
JC8sYkc9L14oLio/KTpbIFx0XSooW15cclxuXSopXHI/JC9tZyxiSD0vXig/OmNvbG9yfGRhdGV8
ZGF0ZXRpbWV8ZGF0ZXRpbWUtbG9jYWx8ZW1haWx8aGlkZGVufG1vbnRofG51bWJlcnxwYXNzd29y
ZHxyYW5nZXxzZWFyY2h8dGVsfHRleHR8dGltZXx1cmx8d2VlaykkL2ksYkk9L14oPzphYm91dHxh
cHB8YXBwXC1zdG9yYWdlfC4rXC1leHRlbnNpb258ZmlsZXxyZXN8d2lkZ2V0KTokLyxiSj0vXig/
OkdFVHxIRUFEKSQvLGJLPS9eXC9cLy8sYkw9L1w/LyxiTT0vPHNjcmlwdFxiW148XSooPzooPyE8
XC9zY3JpcHQ+KTxbXjxdKikqPFwvc2NyaXB0Pi9naSxiTj0vXig/OnNlbGVjdHx0ZXh0YXJlYSkv
aSxiTz0vXHMrLyxiUD0vKFs/Jl0pXz1bXiZdKi8sYlE9L14oW1x3XCtcLlwtXSs6KSg/OlwvXC8o
W15cLz8jOl0qKSg/OjooXGQrKSk/KT8vLGJSPWYuZm4ubG9hZCxiUz17fSxiVD17fSxiVSxiVixi
Vz1bIiovIl0rWyIqIl07dHJ5e2JVPWUuaHJlZn1jYXRjaChiWCl7YlU9Yy5jcmVhdGVFbGVtZW50
KCJhIiksYlUuaHJlZj0iIixiVT1iVS5ocmVmfWJWPWJRLmV4ZWMoYlUudG9Mb3dlckNhc2UoKSl8
fFtdLGYuZm4uZXh0ZW5kKHtsb2FkOmZ1bmN0aW9uKGEsYyxkKXtpZih0eXBlb2YgYSE9InN0cmlu
ZyImJmJSKXJldHVybiBiUi5hcHBseSh0aGlzLGFyZ3VtZW50cyk7aWYoIXRoaXMubGVuZ3RoKXJl
dHVybiB0aGlzO3ZhciBlPWEuaW5kZXhPZigiICIpO2lmKGU+PTApe3ZhciBnPWEuc2xpY2UoZSxh
Lmxlbmd0aCk7YT1hLnNsaWNlKDAsZSl9dmFyIGg9IkdFVCI7YyYmKGYuaXNGdW5jdGlvbihjKT8o
ZD1jLGM9Yik6dHlwZW9mIGM9PSJvYmplY3QiJiYoYz1mLnBhcmFtKGMsZi5hamF4U2V0dGluZ3Mu
dHJhZGl0aW9uYWwpLGg9IlBPU1QiKSk7dmFyIGk9dGhpcztmLmFqYXgoe3VybDphLHR5cGU6aCxk
YXRhVHlwZToiaHRtbCIsZGF0YTpjLGNvbXBsZXRlOmZ1bmN0aW9uKGEsYixjKXtjPWEucmVzcG9u
c2VUZXh0LGEuaXNSZXNvbHZlZCgpJiYoYS5kb25lKGZ1bmN0aW9uKGEpe2M9YX0pLGkuaHRtbChn
P2YoIjxkaXY+IikuYXBwZW5kKGMucmVwbGFjZShiTSwiIikpLmZpbmQoZyk6YykpLGQmJmkuZWFj
aChkLFtjLGIsYV0pfX0pO3JldHVybiB0aGlzfSxzZXJpYWxpemU6ZnVuY3Rpb24oKXtyZXR1cm4g
Zi5wYXJhbSh0aGlzLnNlcmlhbGl6ZUFycmF5KCkpfSxzZXJpYWxpemVBcnJheTpmdW5jdGlvbigp
e3JldHVybiB0aGlzLm1hcChmdW5jdGlvbigpe3JldHVybiB0aGlzLmVsZW1lbnRzP2YubWFrZUFy
cmF5KHRoaXMuZWxlbWVudHMpOnRoaXN9KS5maWx0ZXIoZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5u
YW1lJiYhdGhpcy5kaXNhYmxlZCYmKHRoaXMuY2hlY2tlZHx8Yk4udGVzdCh0aGlzLm5vZGVOYW1l
KXx8YkgudGVzdCh0aGlzLnR5cGUpKX0pLm1hcChmdW5jdGlvbihhLGIpe3ZhciBjPWYodGhpcyku
dmFsKCk7cmV0dXJuIGM9PW51bGw/bnVsbDpmLmlzQXJyYXkoYyk/Zi5tYXAoYyxmdW5jdGlvbihh
LGMpe3JldHVybntuYW1lOmIubmFtZSx2YWx1ZTphLnJlcGxhY2UoYkUsIlxyXG4iKX19KTp7bmFt
ZTpiLm5hbWUsdmFsdWU6Yy5yZXBsYWNlKGJFLCJcclxuIil9fSkuZ2V0KCl9fSksZi5lYWNoKCJh
amF4U3RhcnQgYWpheFN0b3AgYWpheENvbXBsZXRlIGFqYXhFcnJvciBhamF4U3VjY2VzcyBhamF4
U2VuZCIuc3BsaXQoIiAiKSxmdW5jdGlvbihhLGIpe2YuZm5bYl09ZnVuY3Rpb24oYSl7cmV0dXJu
IHRoaXMub24oYixhKX19KSxmLmVhY2goWyJnZXQiLCJwb3N0Il0sZnVuY3Rpb24oYSxjKXtmW2Nd
PWZ1bmN0aW9uKGEsZCxlLGcpe2YuaXNGdW5jdGlvbihkKSYmKGc9Z3x8ZSxlPWQsZD1iKTtyZXR1
cm4gZi5hamF4KHt0eXBlOmMsdXJsOmEsZGF0YTpkLHN1Y2Nlc3M6ZSxkYXRhVHlwZTpnfSl9fSks
Zi5leHRlbmQoe2dldFNjcmlwdDpmdW5jdGlvbihhLGMpe3JldHVybiBmLmdldChhLGIsYywic2Ny
aXB0Iil9LGdldEpTT046ZnVuY3Rpb24oYSxiLGMpe3JldHVybiBmLmdldChhLGIsYywianNvbiIp
fSxhamF4U2V0dXA6ZnVuY3Rpb24oYSxiKXtiP2IkKGEsZi5hamF4U2V0dGluZ3MpOihiPWEsYT1m
LmFqYXhTZXR0aW5ncyksYiQoYSxiKTtyZXR1cm4gYX0sYWpheFNldHRpbmdzOnt1cmw6YlUsaXNM
b2NhbDpiSS50ZXN0KGJWWzFdKSxnbG9iYWw6ITAsdHlwZToiR0VUIixjb250ZW50VHlwZToiYXBw
bGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkOyBjaGFyc2V0PVVURi04Iixwcm9jZXNzRGF0
YTohMCxhc3luYzohMCxhY2NlcHRzOnt4bWw6ImFwcGxpY2F0aW9uL3htbCwgdGV4dC94bWwiLGh0
bWw6InRleHQvaHRtbCIsdGV4dDoidGV4dC9wbGFpbiIsanNvbjoiYXBwbGljYXRpb24vanNvbiwg
dGV4dC9qYXZhc2NyaXB0IiwiKiI6Yld9LGNvbnRlbnRzOnt4bWw6L3htbC8saHRtbDovaHRtbC8s
anNvbjovanNvbi99LHJlc3BvbnNlRmllbGRzOnt4bWw6InJlc3BvbnNlWE1MIix0ZXh0OiJyZXNw
b25zZVRleHQifSxjb252ZXJ0ZXJzOnsiKiB0ZXh0IjphLlN0cmluZywidGV4dCBodG1sIjohMCwi
dGV4dCBqc29uIjpmLnBhcnNlSlNPTiwidGV4dCB4bWwiOmYucGFyc2VYTUx9LGZsYXRPcHRpb25z
Ontjb250ZXh0OiEwLHVybDohMH19LGFqYXhQcmVmaWx0ZXI6YlkoYlMpLGFqYXhUcmFuc3BvcnQ6
YlkoYlQpLGFqYXg6ZnVuY3Rpb24oYSxjKXtmdW5jdGlvbiB3KGEsYyxsLG0pe2lmKHMhPT0yKXtz
PTIscSYmY2xlYXJUaW1lb3V0KHEpLHA9YixuPW18fCIiLHYucmVhZHlTdGF0ZT1hPjA/NDowO3Zh
ciBvLHIsdSx3PWMseD1sP2NhKGQsdixsKTpiLHksejtpZihhPj0yMDAmJmE8MzAwfHxhPT09MzA0
KXtpZihkLmlmTW9kaWZpZWQpe2lmKHk9di5nZXRSZXNwb25zZUhlYWRlcigiTGFzdC1Nb2RpZmll
ZCIpKWYubGFzdE1vZGlmaWVkW2tdPXk7aWYoej12LmdldFJlc3BvbnNlSGVhZGVyKCJFdGFnIikp
Zi5ldGFnW2tdPXp9aWYoYT09PTMwNCl3PSJub3Rtb2RpZmllZCIsbz0hMDtlbHNlIHRyeXtyPWNi
KGQseCksdz0ic3VjY2VzcyIsbz0hMH1jYXRjaChBKXt3PSJwYXJzZXJlcnJvciIsdT1BfX1lbHNl
e3U9dztpZighd3x8YSl3PSJlcnJvciIsYTwwJiYoYT0wKX12LnN0YXR1cz1hLHYuc3RhdHVzVGV4
dD0iIisoY3x8dyksbz9oLnJlc29sdmVXaXRoKGUsW3Isdyx2XSk6aC5yZWplY3RXaXRoKGUsW3Ys
dyx1XSksdi5zdGF0dXNDb2RlKGopLGo9Yix0JiZnLnRyaWdnZXIoImFqYXgiKyhvPyJTdWNjZXNz
IjoiRXJyb3IiKSxbdixkLG8/cjp1XSksaS5maXJlV2l0aChlLFt2LHddKSx0JiYoZy50cmlnZ2Vy
KCJhamF4Q29tcGxldGUiLFt2LGRdKSwtLWYuYWN0aXZlfHxmLmV2ZW50LnRyaWdnZXIoImFqYXhT
dG9wIikpfX10eXBlb2YgYT09Im9iamVjdCImJihjPWEsYT1iKSxjPWN8fHt9O3ZhciBkPWYuYWph
eFNldHVwKHt9LGMpLGU9ZC5jb250ZXh0fHxkLGc9ZSE9PWQmJihlLm5vZGVUeXBlfHxlIGluc3Rh
bmNlb2YgZik/ZihlKTpmLmV2ZW50LGg9Zi5EZWZlcnJlZCgpLGk9Zi5DYWxsYmFja3MoIm9uY2Ug
bWVtb3J5Iiksaj1kLnN0YXR1c0NvZGV8fHt9LGssbD17fSxtPXt9LG4sbyxwLHEscixzPTAsdCx1
LHY9e3JlYWR5U3RhdGU6MCxzZXRSZXF1ZXN0SGVhZGVyOmZ1bmN0aW9uKGEsYil7aWYoIXMpe3Zh
ciBjPWEudG9Mb3dlckNhc2UoKTthPW1bY109bVtjXXx8YSxsW2FdPWJ9cmV0dXJuIHRoaXN9LGdl
dEFsbFJlc3BvbnNlSGVhZGVyczpmdW5jdGlvbigpe3JldHVybiBzPT09Mj9uOm51bGx9LGdldFJl
c3BvbnNlSGVhZGVyOmZ1bmN0aW9uKGEpe3ZhciBjO2lmKHM9PT0yKXtpZighbyl7bz17fTt3aGls
ZShjPWJHLmV4ZWMobikpb1tjWzFdLnRvTG93ZXJDYXNlKCldPWNbMl19Yz1vW2EudG9Mb3dlckNh
c2UoKV19cmV0dXJuIGM9PT1iP251bGw6Y30sb3ZlcnJpZGVNaW1lVHlwZTpmdW5jdGlvbihhKXtz
fHwoZC5taW1lVHlwZT1hKTtyZXR1cm4gdGhpc30sYWJvcnQ6ZnVuY3Rpb24oYSl7YT1hfHwiYWJv
cnQiLHAmJnAuYWJvcnQoYSksdygwLGEpO3JldHVybiB0aGlzfX07aC5wcm9taXNlKHYpLHYuc3Vj
Y2Vzcz12LmRvbmUsdi5lcnJvcj12LmZhaWwsdi5jb21wbGV0ZT1pLmFkZCx2LnN0YXR1c0NvZGU9
ZnVuY3Rpb24oYSl7aWYoYSl7dmFyIGI7aWYoczwyKWZvcihiIGluIGEpaltiXT1baltiXSxhW2Jd
XTtlbHNlIGI9YVt2LnN0YXR1c10sdi50aGVuKGIsYil9cmV0dXJuIHRoaXN9LGQudXJsPSgoYXx8
ZC51cmwpKyIiKS5yZXBsYWNlKGJGLCIiKS5yZXBsYWNlKGJLLGJWWzFdKyIvLyIpLGQuZGF0YVR5
cGVzPWYudHJpbShkLmRhdGFUeXBlfHwiKiIpLnRvTG93ZXJDYXNlKCkuc3BsaXQoYk8pLGQuY3Jv
c3NEb21haW49PW51bGwmJihyPWJRLmV4ZWMoZC51cmwudG9Mb3dlckNhc2UoKSksZC5jcm9zc0Rv
bWFpbj0hKCFyfHxyWzFdPT1iVlsxXSYmclsyXT09YlZbMl0mJihyWzNdfHwoclsxXT09PSJodHRw
OiI/ODA6NDQzKSk9PShiVlszXXx8KGJWWzFdPT09Imh0dHA6Ij84MDo0NDMpKSkpLGQuZGF0YSYm
ZC5wcm9jZXNzRGF0YSYmdHlwZW9mIGQuZGF0YSE9InN0cmluZyImJihkLmRhdGE9Zi5wYXJhbShk
LmRhdGEsZC50cmFkaXRpb25hbCkpLGJaKGJTLGQsYyx2KTtpZihzPT09MilyZXR1cm4hMTt0PWQu
Z2xvYmFsLGQudHlwZT1kLnR5cGUudG9VcHBlckNhc2UoKSxkLmhhc0NvbnRlbnQ9IWJKLnRlc3Qo
ZC50eXBlKSx0JiZmLmFjdGl2ZSsrPT09MCYmZi5ldmVudC50cmlnZ2VyKCJhamF4U3RhcnQiKTtp
ZighZC5oYXNDb250ZW50KXtkLmRhdGEmJihkLnVybCs9KGJMLnRlc3QoZC51cmwpPyImIjoiPyIp
K2QuZGF0YSxkZWxldGUgZC5kYXRhKSxrPWQudXJsO2lmKGQuY2FjaGU9PT0hMSl7dmFyIHg9Zi5u
b3coKSx5PWQudXJsLnJlcGxhY2UoYlAsIiQxXz0iK3gpO2QudXJsPXkrKHk9PT1kLnVybD8oYkwu
dGVzdChkLnVybCk/IiYiOiI/IikrIl89Iit4OiIiKX19KGQuZGF0YSYmZC5oYXNDb250ZW50JiZk
LmNvbnRlbnRUeXBlIT09ITF8fGMuY29udGVudFR5cGUpJiZ2LnNldFJlcXVlc3RIZWFkZXIoIkNv
bnRlbnQtVHlwZSIsZC5jb250ZW50VHlwZSksZC5pZk1vZGlmaWVkJiYoaz1rfHxkLnVybCxmLmxh
c3RNb2RpZmllZFtrXSYmdi5zZXRSZXF1ZXN0SGVhZGVyKCJJZi1Nb2RpZmllZC1TaW5jZSIsZi5s
YXN0TW9kaWZpZWRba10pLGYuZXRhZ1trXSYmdi5zZXRSZXF1ZXN0SGVhZGVyKCJJZi1Ob25lLU1h
dGNoIixmLmV0YWdba10pKSx2LnNldFJlcXVlc3RIZWFkZXIoIkFjY2VwdCIsZC5kYXRhVHlwZXNb
MF0mJmQuYWNjZXB0c1tkLmRhdGFUeXBlc1swXV0/ZC5hY2NlcHRzW2QuZGF0YVR5cGVzWzBdXSso
ZC5kYXRhVHlwZXNbMF0hPT0iKiI/IiwgIitiVysiOyBxPTAuMDEiOiIiKTpkLmFjY2VwdHNbIioi
XSk7Zm9yKHUgaW4gZC5oZWFkZXJzKXYuc2V0UmVxdWVzdEhlYWRlcih1LGQuaGVhZGVyc1t1XSk7
aWYoZC5iZWZvcmVTZW5kJiYoZC5iZWZvcmVTZW5kLmNhbGwoZSx2LGQpPT09ITF8fHM9PT0yKSl7
di5hYm9ydCgpO3JldHVybiExfWZvcih1IGlue3N1Y2Nlc3M6MSxlcnJvcjoxLGNvbXBsZXRlOjF9
KXZbdV0oZFt1XSk7cD1iWihiVCxkLGMsdik7aWYoIXApdygtMSwiTm8gVHJhbnNwb3J0Iik7ZWxz
ZXt2LnJlYWR5U3RhdGU9MSx0JiZnLnRyaWdnZXIoImFqYXhTZW5kIixbdixkXSksZC5hc3luYyYm
ZC50aW1lb3V0PjAmJihxPXNldFRpbWVvdXQoZnVuY3Rpb24oKXt2LmFib3J0KCJ0aW1lb3V0Iil9
LGQudGltZW91dCkpO3RyeXtzPTEscC5zZW5kKGwsdyl9Y2F0Y2goeil7aWYoczwyKXcoLTEseik7
ZWxzZSB0aHJvdyB6fX1yZXR1cm4gdn0scGFyYW06ZnVuY3Rpb24oYSxjKXt2YXIgZD1bXSxlPWZ1
bmN0aW9uKGEsYil7Yj1mLmlzRnVuY3Rpb24oYik/YigpOmIsZFtkLmxlbmd0aF09ZW5jb2RlVVJJ
Q29tcG9uZW50KGEpKyI9IitlbmNvZGVVUklDb21wb25lbnQoYil9O2M9PT1iJiYoYz1mLmFqYXhT
ZXR0aW5ncy50cmFkaXRpb25hbCk7aWYoZi5pc0FycmF5KGEpfHxhLmpxdWVyeSYmIWYuaXNQbGFp
bk9iamVjdChhKSlmLmVhY2goYSxmdW5jdGlvbigpe2UodGhpcy5uYW1lLHRoaXMudmFsdWUpfSk7
ZWxzZSBmb3IodmFyIGcgaW4gYSliXyhnLGFbZ10sYyxlKTtyZXR1cm4gZC5qb2luKCImIikucmVw
bGFjZShiQywiKyIpfX0pLGYuZXh0ZW5kKHthY3RpdmU6MCxsYXN0TW9kaWZpZWQ6e30sZXRhZzp7
fX0pO3ZhciBjYz1mLm5vdygpLGNkPS8oXD0pXD8oJnwkKXxcP1w/L2k7Zi5hamF4U2V0dXAoe2pz
b25wOiJjYWxsYmFjayIsanNvbnBDYWxsYmFjazpmdW5jdGlvbigpe3JldHVybiBmLmV4cGFuZG8r
Il8iK2NjKyt9fSksZi5hamF4UHJlZmlsdGVyKCJqc29uIGpzb25wIixmdW5jdGlvbihiLGMsZCl7
dmFyIGU9dHlwZW9mIGIuZGF0YT09InN0cmluZyImJi9eYXBwbGljYXRpb25cL3hcLXd3d1wtZm9y
bVwtdXJsZW5jb2RlZC8udGVzdChiLmNvbnRlbnRUeXBlKTtpZihiLmRhdGFUeXBlc1swXT09PSJq
c29ucCJ8fGIuanNvbnAhPT0hMSYmKGNkLnRlc3QoYi51cmwpfHxlJiZjZC50ZXN0KGIuZGF0YSkp
KXt2YXIgZyxoPWIuanNvbnBDYWxsYmFjaz1mLmlzRnVuY3Rpb24oYi5qc29ucENhbGxiYWNrKT9i
Lmpzb25wQ2FsbGJhY2soKTpiLmpzb25wQ2FsbGJhY2ssaT1hW2hdLGo9Yi51cmwsaz1iLmRhdGEs
bD0iJDEiK2grIiQyIjtiLmpzb25wIT09ITEmJihqPWoucmVwbGFjZShjZCxsKSxiLnVybD09PWom
JihlJiYoaz1rLnJlcGxhY2UoY2QsbCkpLGIuZGF0YT09PWsmJihqKz0oL1w/Ly50ZXN0KGopPyIm
IjoiPyIpK2IuanNvbnArIj0iK2gpKSksYi51cmw9aixiLmRhdGE9ayxhW2hdPWZ1bmN0aW9uKGEp
e2c9W2FdfSxkLmFsd2F5cyhmdW5jdGlvbigpe2FbaF09aSxnJiZmLmlzRnVuY3Rpb24oaSkmJmFb
aF0oZ1swXSl9KSxiLmNvbnZlcnRlcnNbInNjcmlwdCBqc29uIl09ZnVuY3Rpb24oKXtnfHxmLmVy
cm9yKGgrIiB3YXMgbm90IGNhbGxlZCIpO3JldHVybiBnWzBdfSxiLmRhdGFUeXBlc1swXT0ianNv
biI7cmV0dXJuInNjcmlwdCJ9fSksZi5hamF4U2V0dXAoe2FjY2VwdHM6e3NjcmlwdDoidGV4dC9q
YXZhc2NyaXB0LCBhcHBsaWNhdGlvbi9qYXZhc2NyaXB0LCBhcHBsaWNhdGlvbi9lY21hc2NyaXB0
LCBhcHBsaWNhdGlvbi94LWVjbWFzY3JpcHQifSxjb250ZW50czp7c2NyaXB0Oi9qYXZhc2NyaXB0
fGVjbWFzY3JpcHQvfSxjb252ZXJ0ZXJzOnsidGV4dCBzY3JpcHQiOmZ1bmN0aW9uKGEpe2YuZ2xv
YmFsRXZhbChhKTtyZXR1cm4gYX19fSksZi5hamF4UHJlZmlsdGVyKCJzY3JpcHQiLGZ1bmN0aW9u
KGEpe2EuY2FjaGU9PT1iJiYoYS5jYWNoZT0hMSksYS5jcm9zc0RvbWFpbiYmKGEudHlwZT0iR0VU
IixhLmdsb2JhbD0hMSl9KSxmLmFqYXhUcmFuc3BvcnQoInNjcmlwdCIsZnVuY3Rpb24oYSl7aWYo
YS5jcm9zc0RvbWFpbil7dmFyIGQsZT1jLmhlYWR8fGMuZ2V0RWxlbWVudHNCeVRhZ05hbWUoImhl
YWQiKVswXXx8Yy5kb2N1bWVudEVsZW1lbnQ7cmV0dXJue3NlbmQ6ZnVuY3Rpb24oZixnKXtkPWMu
Y3JlYXRlRWxlbWVudCgic2NyaXB0IiksZC5hc3luYz0iYXN5bmMiLGEuc2NyaXB0Q2hhcnNldCYm
KGQuY2hhcnNldD1hLnNjcmlwdENoYXJzZXQpLGQuc3JjPWEudXJsLGQub25sb2FkPWQub25yZWFk
eXN0YXRlY2hhbmdlPWZ1bmN0aW9uKGEsYyl7aWYoY3x8IWQucmVhZHlTdGF0ZXx8L2xvYWRlZHxj
b21wbGV0ZS8udGVzdChkLnJlYWR5U3RhdGUpKWQub25sb2FkPWQub25yZWFkeXN0YXRlY2hhbmdl
PW51bGwsZSYmZC5wYXJlbnROb2RlJiZlLnJlbW92ZUNoaWxkKGQpLGQ9YixjfHxnKDIwMCwic3Vj
Y2VzcyIpfSxlLmluc2VydEJlZm9yZShkLGUuZmlyc3RDaGlsZCl9LGFib3J0OmZ1bmN0aW9uKCl7
ZCYmZC5vbmxvYWQoMCwxKX19fX0pO3ZhciBjZT1hLkFjdGl2ZVhPYmplY3Q/ZnVuY3Rpb24oKXtm
b3IodmFyIGEgaW4gY2cpY2dbYV0oMCwxKX06ITEsY2Y9MCxjZztmLmFqYXhTZXR0aW5ncy54aHI9
YS5BY3RpdmVYT2JqZWN0P2Z1bmN0aW9uKCl7cmV0dXJuIXRoaXMuaXNMb2NhbCYmY2goKXx8Y2ko
KX06Y2gsZnVuY3Rpb24oYSl7Zi5leHRlbmQoZi5zdXBwb3J0LHthamF4OiEhYSxjb3JzOiEhYSYm
IndpdGhDcmVkZW50aWFscyJpbiBhfSl9KGYuYWpheFNldHRpbmdzLnhocigpKSxmLnN1cHBvcnQu
YWpheCYmZi5hamF4VHJhbnNwb3J0KGZ1bmN0aW9uKGMpe2lmKCFjLmNyb3NzRG9tYWlufHxmLnN1
cHBvcnQuY29ycyl7dmFyIGQ7cmV0dXJue3NlbmQ6ZnVuY3Rpb24oZSxnKXt2YXIgaD1jLnhocigp
LGksajtjLnVzZXJuYW1lP2gub3BlbihjLnR5cGUsYy51cmwsYy5hc3luYyxjLnVzZXJuYW1lLGMu
cGFzc3dvcmQpOmgub3BlbihjLnR5cGUsYy51cmwsYy5hc3luYyk7aWYoYy54aHJGaWVsZHMpZm9y
KGogaW4gYy54aHJGaWVsZHMpaFtqXT1jLnhockZpZWxkc1tqXTtjLm1pbWVUeXBlJiZoLm92ZXJy
aWRlTWltZVR5cGUmJmgub3ZlcnJpZGVNaW1lVHlwZShjLm1pbWVUeXBlKSwhYy5jcm9zc0RvbWFp
biYmIWVbIlgtUmVxdWVzdGVkLVdpdGgiXSYmKGVbIlgtUmVxdWVzdGVkLVdpdGgiXT0iWE1MSHR0
cFJlcXVlc3QiKTt0cnl7Zm9yKGogaW4gZSloLnNldFJlcXVlc3RIZWFkZXIoaixlW2pdKX1jYXRj
aChrKXt9aC5zZW5kKGMuaGFzQ29udGVudCYmYy5kYXRhfHxudWxsKSxkPWZ1bmN0aW9uKGEsZSl7
dmFyIGosayxsLG0sbjt0cnl7aWYoZCYmKGV8fGgucmVhZHlTdGF0ZT09PTQpKXtkPWIsaSYmKGgu
b25yZWFkeXN0YXRlY2hhbmdlPWYubm9vcCxjZSYmZGVsZXRlIGNnW2ldKTtpZihlKWgucmVhZHlT
dGF0ZSE9PTQmJmguYWJvcnQoKTtlbHNle2o9aC5zdGF0dXMsbD1oLmdldEFsbFJlc3BvbnNlSGVh
ZGVycygpLG09e30sbj1oLnJlc3BvbnNlWE1MLG4mJm4uZG9jdW1lbnRFbGVtZW50JiYobS54bWw9
bik7dHJ5e20udGV4dD1oLnJlc3BvbnNlVGV4dH1jYXRjaChhKXt9dHJ5e2s9aC5zdGF0dXNUZXh0
fWNhdGNoKG8pe2s9IiJ9IWomJmMuaXNMb2NhbCYmIWMuY3Jvc3NEb21haW4/aj1tLnRleHQ/MjAw
OjQwNDpqPT09MTIyMyYmKGo9MjA0KX19fWNhdGNoKHApe2V8fGcoLTEscCl9bSYmZyhqLGssbSxs
KX0sIWMuYXN5bmN8fGgucmVhZHlTdGF0ZT09PTQ/ZCgpOihpPSsrY2YsY2UmJihjZ3x8KGNnPXt9
LGYoYSkudW5sb2FkKGNlKSksY2dbaV09ZCksaC5vbnJlYWR5c3RhdGVjaGFuZ2U9ZCl9LGFib3J0
OmZ1bmN0aW9uKCl7ZCYmZCgwLDEpfX19fSk7dmFyIGNqPXt9LGNrLGNsLGNtPS9eKD86dG9nZ2xl
fHNob3d8aGlkZSkkLyxjbj0vXihbK1wtXT0pPyhbXGQrLlwtXSspKFthLXolXSopJC9pLGNvLGNw
PVtbImhlaWdodCIsIm1hcmdpblRvcCIsIm1hcmdpbkJvdHRvbSIsInBhZGRpbmdUb3AiLCJwYWRk
aW5nQm90dG9tIl0sWyJ3aWR0aCIsIm1hcmdpbkxlZnQiLCJtYXJnaW5SaWdodCIsInBhZGRpbmdM
ZWZ0IiwicGFkZGluZ1JpZ2h0Il0sWyJvcGFjaXR5Il1dLGNxO2YuZm4uZXh0ZW5kKHtzaG93OmZ1
bmN0aW9uKGEsYixjKXt2YXIgZCxlO2lmKGF8fGE9PT0wKXJldHVybiB0aGlzLmFuaW1hdGUoY3Qo
InNob3ciLDMpLGEsYixjKTtmb3IodmFyIGc9MCxoPXRoaXMubGVuZ3RoO2c8aDtnKyspZD10aGlz
W2ddLGQuc3R5bGUmJihlPWQuc3R5bGUuZGlzcGxheSwhZi5fZGF0YShkLCJvbGRkaXNwbGF5Iikm
JmU9PT0ibm9uZSImJihlPWQuc3R5bGUuZGlzcGxheT0iIiksKGU9PT0iIiYmZi5jc3MoZCwiZGlz
cGxheSIpPT09Im5vbmUifHwhZi5jb250YWlucyhkLm93bmVyRG9jdW1lbnQuZG9jdW1lbnRFbGVt
ZW50LGQpKSYmZi5fZGF0YShkLCJvbGRkaXNwbGF5IixjdShkLm5vZGVOYW1lKSkpO2ZvcihnPTA7
ZzxoO2crKyl7ZD10aGlzW2ddO2lmKGQuc3R5bGUpe2U9ZC5zdHlsZS5kaXNwbGF5O2lmKGU9PT0i
Inx8ZT09PSJub25lIilkLnN0eWxlLmRpc3BsYXk9Zi5fZGF0YShkLCJvbGRkaXNwbGF5Iil8fCIi
fX1yZXR1cm4gdGhpc30saGlkZTpmdW5jdGlvbihhLGIsYyl7aWYoYXx8YT09PTApcmV0dXJuIHRo
aXMuYW5pbWF0ZShjdCgiaGlkZSIsMyksYSxiLGMpO3ZhciBkLGUsZz0wLGg9dGhpcy5sZW5ndGg7
Zm9yKDtnPGg7ZysrKWQ9dGhpc1tnXSxkLnN0eWxlJiYoZT1mLmNzcyhkLCJkaXNwbGF5IiksZSE9
PSJub25lIiYmIWYuX2RhdGEoZCwib2xkZGlzcGxheSIpJiZmLl9kYXRhKGQsIm9sZGRpc3BsYXki
LGUpKTtmb3IoZz0wO2c8aDtnKyspdGhpc1tnXS5zdHlsZSYmKHRoaXNbZ10uc3R5bGUuZGlzcGxh
eT0ibm9uZSIpO3JldHVybiB0aGlzfSxfdG9nZ2xlOmYuZm4udG9nZ2xlLHRvZ2dsZTpmdW5jdGlv
bihhLGIsYyl7dmFyIGQ9dHlwZW9mIGE9PSJib29sZWFuIjtmLmlzRnVuY3Rpb24oYSkmJmYuaXNG
dW5jdGlvbihiKT90aGlzLl90b2dnbGUuYXBwbHkodGhpcyxhcmd1bWVudHMpOmE9PW51bGx8fGQ/
dGhpcy5lYWNoKGZ1bmN0aW9uKCl7dmFyIGI9ZD9hOmYodGhpcykuaXMoIjpoaWRkZW4iKTtmKHRo
aXMpW2I/InNob3ciOiJoaWRlIl0oKX0pOnRoaXMuYW5pbWF0ZShjdCgidG9nZ2xlIiwzKSxhLGIs
Yyk7cmV0dXJuIHRoaXN9LGZhZGVUbzpmdW5jdGlvbihhLGIsYyxkKXtyZXR1cm4gdGhpcy5maWx0
ZXIoIjpoaWRkZW4iKS5jc3MoIm9wYWNpdHkiLDApLnNob3coKS5lbmQoKS5hbmltYXRlKHtvcGFj
aXR5OmJ9LGEsYyxkKX0sYW5pbWF0ZTpmdW5jdGlvbihhLGIsYyxkKXtmdW5jdGlvbiBnKCl7ZS5x
dWV1ZT09PSExJiZmLl9tYXJrKHRoaXMpO3ZhciBiPWYuZXh0ZW5kKHt9LGUpLGM9dGhpcy5ub2Rl
VHlwZT09PTEsZD1jJiZmKHRoaXMpLmlzKCI6aGlkZGVuIiksZyxoLGksaixrLGwsbSxuLG8scCxx
O2IuYW5pbWF0ZWRQcm9wZXJ0aWVzPXt9O2ZvcihpIGluIGEpe2c9Zi5jYW1lbENhc2UoaSksaSE9
PWcmJihhW2ddPWFbaV0sZGVsZXRlIGFbaV0pO2lmKChrPWYuY3NzSG9va3NbZ10pJiYiZXhwYW5k
ImluIGspe2w9ay5leHBhbmQoYVtnXSksZGVsZXRlIGFbZ107Zm9yKGkgaW4gbClpIGluIGF8fChh
W2ldPWxbaV0pfX1mb3IoZyBpbiBhKXtoPWFbZ10sZi5pc0FycmF5KGgpPyhiLmFuaW1hdGVkUHJv
cGVydGllc1tnXT1oWzFdLGg9YVtnXT1oWzBdKTpiLmFuaW1hdGVkUHJvcGVydGllc1tnXT1iLnNw
ZWNpYWxFYXNpbmcmJmIuc3BlY2lhbEVhc2luZ1tnXXx8Yi5lYXNpbmd8fCJzd2luZyI7aWYoaD09
PSJoaWRlIiYmZHx8aD09PSJzaG93IiYmIWQpcmV0dXJuIGIuY29tcGxldGUuY2FsbCh0aGlzKTtj
JiYoZz09PSJoZWlnaHQifHxnPT09IndpZHRoIikmJihiLm92ZXJmbG93PVt0aGlzLnN0eWxlLm92
ZXJmbG93LHRoaXMuc3R5bGUub3ZlcmZsb3dYLHRoaXMuc3R5bGUub3ZlcmZsb3dZXSxmLmNzcyh0
aGlzLCJkaXNwbGF5Iik9PT0iaW5saW5lIiYmZi5jc3ModGhpcywiZmxvYXQiKT09PSJub25lIiYm
KCFmLnN1cHBvcnQuaW5saW5lQmxvY2tOZWVkc0xheW91dHx8Y3UodGhpcy5ub2RlTmFtZSk9PT0i
aW5saW5lIj90aGlzLnN0eWxlLmRpc3BsYXk9ImlubGluZS1ibG9jayI6dGhpcy5zdHlsZS56b29t
PTEpKX1iLm92ZXJmbG93IT1udWxsJiYodGhpcy5zdHlsZS5vdmVyZmxvdz0iaGlkZGVuIik7Zm9y
KGkgaW4gYSlqPW5ldyBmLmZ4KHRoaXMsYixpKSxoPWFbaV0sY20udGVzdChoKT8ocT1mLl9kYXRh
KHRoaXMsInRvZ2dsZSIraSl8fChoPT09InRvZ2dsZSI/ZD8ic2hvdyI6ImhpZGUiOjApLHE/KGYu
X2RhdGEodGhpcywidG9nZ2xlIitpLHE9PT0ic2hvdyI/ImhpZGUiOiJzaG93IiksaltxXSgpKTpq
W2hdKCkpOihtPWNuLmV4ZWMoaCksbj1qLmN1cigpLG0/KG89cGFyc2VGbG9hdChtWzJdKSxwPW1b
M118fChmLmNzc051bWJlcltpXT8iIjoicHgiKSxwIT09InB4IiYmKGYuc3R5bGUodGhpcyxpLChv
fHwxKStwKSxuPShvfHwxKS9qLmN1cigpKm4sZi5zdHlsZSh0aGlzLGksbitwKSksbVsxXSYmKG89
KG1bMV09PT0iLT0iPy0xOjEpKm8rbiksai5jdXN0b20obixvLHApKTpqLmN1c3RvbShuLGgsIiIp
KTtyZXR1cm4hMH12YXIgZT1mLnNwZWVkKGIsYyxkKTtpZihmLmlzRW1wdHlPYmplY3QoYSkpcmV0
dXJuIHRoaXMuZWFjaChlLmNvbXBsZXRlLFshMV0pO2E9Zi5leHRlbmQoe30sYSk7cmV0dXJuIGUu
cXVldWU9PT0hMT90aGlzLmVhY2goZyk6dGhpcy5xdWV1ZShlLnF1ZXVlLGcpfSxzdG9wOmZ1bmN0
aW9uKGEsYyxkKXt0eXBlb2YgYSE9InN0cmluZyImJihkPWMsYz1hLGE9YiksYyYmYSE9PSExJiZ0
aGlzLnF1ZXVlKGF8fCJmeCIsW10pO3JldHVybiB0aGlzLmVhY2goZnVuY3Rpb24oKXtmdW5jdGlv
biBoKGEsYixjKXt2YXIgZT1iW2NdO2YucmVtb3ZlRGF0YShhLGMsITApLGUuc3RvcChkKX12YXIg
YixjPSExLGU9Zi50aW1lcnMsZz1mLl9kYXRhKHRoaXMpO2R8fGYuX3VubWFyayghMCx0aGlzKTtp
ZihhPT1udWxsKWZvcihiIGluIGcpZ1tiXSYmZ1tiXS5zdG9wJiZiLmluZGV4T2YoIi5ydW4iKT09
PWIubGVuZ3RoLTQmJmgodGhpcyxnLGIpO2Vsc2UgZ1tiPWErIi5ydW4iXSYmZ1tiXS5zdG9wJiZo
KHRoaXMsZyxiKTtmb3IoYj1lLmxlbmd0aDtiLS07KWVbYl0uZWxlbT09PXRoaXMmJihhPT1udWxs
fHxlW2JdLnF1ZXVlPT09YSkmJihkP2VbYl0oITApOmVbYl0uc2F2ZVN0YXRlKCksYz0hMCxlLnNw
bGljZShiLDEpKTsoIWR8fCFjKSYmZi5kZXF1ZXVlKHRoaXMsYSl9KX19KSxmLmVhY2goe3NsaWRl
RG93bjpjdCgic2hvdyIsMSksc2xpZGVVcDpjdCgiaGlkZSIsMSksc2xpZGVUb2dnbGU6Y3QoInRv
Z2dsZSIsMSksZmFkZUluOntvcGFjaXR5OiJzaG93In0sZmFkZU91dDp7b3BhY2l0eToiaGlkZSJ9
LGZhZGVUb2dnbGU6e29wYWNpdHk6InRvZ2dsZSJ9fSxmdW5jdGlvbihhLGIpe2YuZm5bYV09ZnVu
Y3Rpb24oYSxjLGQpe3JldHVybiB0aGlzLmFuaW1hdGUoYixhLGMsZCl9fSksZi5leHRlbmQoe3Nw
ZWVkOmZ1bmN0aW9uKGEsYixjKXt2YXIgZD1hJiZ0eXBlb2YgYT09Im9iamVjdCI/Zi5leHRlbmQo
e30sYSk6e2NvbXBsZXRlOmN8fCFjJiZifHxmLmlzRnVuY3Rpb24oYSkmJmEsZHVyYXRpb246YSxl
YXNpbmc6YyYmYnx8YiYmIWYuaXNGdW5jdGlvbihiKSYmYn07ZC5kdXJhdGlvbj1mLmZ4Lm9mZj8w
OnR5cGVvZiBkLmR1cmF0aW9uPT0ibnVtYmVyIj9kLmR1cmF0aW9uOmQuZHVyYXRpb24gaW4gZi5m
eC5zcGVlZHM/Zi5meC5zcGVlZHNbZC5kdXJhdGlvbl06Zi5meC5zcGVlZHMuX2RlZmF1bHQ7aWYo
ZC5xdWV1ZT09bnVsbHx8ZC5xdWV1ZT09PSEwKWQucXVldWU9ImZ4IjtkLm9sZD1kLmNvbXBsZXRl
LGQuY29tcGxldGU9ZnVuY3Rpb24oYSl7Zi5pc0Z1bmN0aW9uKGQub2xkKSYmZC5vbGQuY2FsbCh0
aGlzKSxkLnF1ZXVlP2YuZGVxdWV1ZSh0aGlzLGQucXVldWUpOmEhPT0hMSYmZi5fdW5tYXJrKHRo
aXMpfTtyZXR1cm4gZH0sZWFzaW5nOntsaW5lYXI6ZnVuY3Rpb24oYSl7cmV0dXJuIGF9LHN3aW5n
OmZ1bmN0aW9uKGEpe3JldHVybi1NYXRoLmNvcyhhKk1hdGguUEkpLzIrLjV9fSx0aW1lcnM6W10s
Zng6ZnVuY3Rpb24oYSxiLGMpe3RoaXMub3B0aW9ucz1iLHRoaXMuZWxlbT1hLHRoaXMucHJvcD1j
LGIub3JpZz1iLm9yaWd8fHt9fX0pLGYuZngucHJvdG90eXBlPXt1cGRhdGU6ZnVuY3Rpb24oKXt0
aGlzLm9wdGlvbnMuc3RlcCYmdGhpcy5vcHRpb25zLnN0ZXAuY2FsbCh0aGlzLmVsZW0sdGhpcy5u
b3csdGhpcyksKGYuZnguc3RlcFt0aGlzLnByb3BdfHxmLmZ4LnN0ZXAuX2RlZmF1bHQpKHRoaXMp
fSxjdXI6ZnVuY3Rpb24oKXtpZih0aGlzLmVsZW1bdGhpcy5wcm9wXSE9bnVsbCYmKCF0aGlzLmVs
ZW0uc3R5bGV8fHRoaXMuZWxlbS5zdHlsZVt0aGlzLnByb3BdPT1udWxsKSlyZXR1cm4gdGhpcy5l
bGVtW3RoaXMucHJvcF07dmFyIGEsYj1mLmNzcyh0aGlzLmVsZW0sdGhpcy5wcm9wKTtyZXR1cm4g
aXNOYU4oYT1wYXJzZUZsb2F0KGIpKT8hYnx8Yj09PSJhdXRvIj8wOmI6YX0sY3VzdG9tOmZ1bmN0
aW9uKGEsYyxkKXtmdW5jdGlvbiBoKGEpe3JldHVybiBlLnN0ZXAoYSl9dmFyIGU9dGhpcyxnPWYu
Zng7dGhpcy5zdGFydFRpbWU9Y3F8fGNyKCksdGhpcy5lbmQ9Yyx0aGlzLm5vdz10aGlzLnN0YXJ0
PWEsdGhpcy5wb3M9dGhpcy5zdGF0ZT0wLHRoaXMudW5pdD1kfHx0aGlzLnVuaXR8fChmLmNzc051
bWJlclt0aGlzLnByb3BdPyIiOiJweCIpLGgucXVldWU9dGhpcy5vcHRpb25zLnF1ZXVlLGguZWxl
bT10aGlzLmVsZW0saC5zYXZlU3RhdGU9ZnVuY3Rpb24oKXtmLl9kYXRhKGUuZWxlbSwiZnhzaG93
IitlLnByb3ApPT09YiYmKGUub3B0aW9ucy5oaWRlP2YuX2RhdGEoZS5lbGVtLCJmeHNob3ciK2Uu
cHJvcCxlLnN0YXJ0KTplLm9wdGlvbnMuc2hvdyYmZi5fZGF0YShlLmVsZW0sImZ4c2hvdyIrZS5w
cm9wLGUuZW5kKSl9LGgoKSYmZi50aW1lcnMucHVzaChoKSYmIWNvJiYoY289c2V0SW50ZXJ2YWwo
Zy50aWNrLGcuaW50ZXJ2YWwpKX0sc2hvdzpmdW5jdGlvbigpe3ZhciBhPWYuX2RhdGEodGhpcy5l
bGVtLCJmeHNob3ciK3RoaXMucHJvcCk7dGhpcy5vcHRpb25zLm9yaWdbdGhpcy5wcm9wXT1hfHxm
LnN0eWxlKHRoaXMuZWxlbSx0aGlzLnByb3ApLHRoaXMub3B0aW9ucy5zaG93PSEwLGEhPT1iP3Ro
aXMuY3VzdG9tKHRoaXMuY3VyKCksYSk6dGhpcy5jdXN0b20odGhpcy5wcm9wPT09IndpZHRoInx8
dGhpcy5wcm9wPT09ImhlaWdodCI/MTowLHRoaXMuY3VyKCkpLGYodGhpcy5lbGVtKS5zaG93KCl9
LGhpZGU6ZnVuY3Rpb24oKXt0aGlzLm9wdGlvbnMub3JpZ1t0aGlzLnByb3BdPWYuX2RhdGEodGhp
cy5lbGVtLCJmeHNob3ciK3RoaXMucHJvcCl8fGYuc3R5bGUodGhpcy5lbGVtLHRoaXMucHJvcCks
dGhpcy5vcHRpb25zLmhpZGU9ITAsdGhpcy5jdXN0b20odGhpcy5jdXIoKSwwKX0sc3RlcDpmdW5j
dGlvbihhKXt2YXIgYixjLGQsZT1jcXx8Y3IoKSxnPSEwLGg9dGhpcy5lbGVtLGk9dGhpcy5vcHRp
b25zO2lmKGF8fGU+PWkuZHVyYXRpb24rdGhpcy5zdGFydFRpbWUpe3RoaXMubm93PXRoaXMuZW5k
LHRoaXMucG9zPXRoaXMuc3RhdGU9MSx0aGlzLnVwZGF0ZSgpLGkuYW5pbWF0ZWRQcm9wZXJ0aWVz
W3RoaXMucHJvcF09ITA7Zm9yKGIgaW4gaS5hbmltYXRlZFByb3BlcnRpZXMpaS5hbmltYXRlZFBy
b3BlcnRpZXNbYl0hPT0hMCYmKGc9ITEpO2lmKGcpe2kub3ZlcmZsb3chPW51bGwmJiFmLnN1cHBv
cnQuc2hyaW5rV3JhcEJsb2NrcyYmZi5lYWNoKFsiIiwiWCIsIlkiXSxmdW5jdGlvbihhLGIpe2gu
c3R5bGVbIm92ZXJmbG93IitiXT1pLm92ZXJmbG93W2FdfSksaS5oaWRlJiZmKGgpLmhpZGUoKTtp
ZihpLmhpZGV8fGkuc2hvdylmb3IoYiBpbiBpLmFuaW1hdGVkUHJvcGVydGllcylmLnN0eWxlKGgs
YixpLm9yaWdbYl0pLGYucmVtb3ZlRGF0YShoLCJmeHNob3ciK2IsITApLGYucmVtb3ZlRGF0YSho
LCJ0b2dnbGUiK2IsITApO2Q9aS5jb21wbGV0ZSxkJiYoaS5jb21wbGV0ZT0hMSxkLmNhbGwoaCkp
fXJldHVybiExfWkuZHVyYXRpb249PUluZmluaXR5P3RoaXMubm93PWU6KGM9ZS10aGlzLnN0YXJ0
VGltZSx0aGlzLnN0YXRlPWMvaS5kdXJhdGlvbix0aGlzLnBvcz1mLmVhc2luZ1tpLmFuaW1hdGVk
UHJvcGVydGllc1t0aGlzLnByb3BdXSh0aGlzLnN0YXRlLGMsMCwxLGkuZHVyYXRpb24pLHRoaXMu
bm93PXRoaXMuc3RhcnQrKHRoaXMuZW5kLXRoaXMuc3RhcnQpKnRoaXMucG9zKSx0aGlzLnVwZGF0
ZSgpO3JldHVybiEwfX0sZi5leHRlbmQoZi5meCx7dGljazpmdW5jdGlvbigpe3ZhciBhLGI9Zi50
aW1lcnMsYz0wO2Zvcig7YzxiLmxlbmd0aDtjKyspYT1iW2NdLCFhKCkmJmJbY109PT1hJiZiLnNw
bGljZShjLS0sMSk7Yi5sZW5ndGh8fGYuZnguc3RvcCgpfSxpbnRlcnZhbDoxMyxzdG9wOmZ1bmN0
aW9uKCl7Y2xlYXJJbnRlcnZhbChjbyksY289bnVsbH0sc3BlZWRzOntzbG93OjYwMCxmYXN0OjIw
MCxfZGVmYXVsdDo0MDB9LHN0ZXA6e29wYWNpdHk6ZnVuY3Rpb24oYSl7Zi5zdHlsZShhLmVsZW0s
Im9wYWNpdHkiLGEubm93KX0sX2RlZmF1bHQ6ZnVuY3Rpb24oYSl7YS5lbGVtLnN0eWxlJiZhLmVs
ZW0uc3R5bGVbYS5wcm9wXSE9bnVsbD9hLmVsZW0uc3R5bGVbYS5wcm9wXT1hLm5vdythLnVuaXQ6
YS5lbGVtW2EucHJvcF09YS5ub3d9fX0pLGYuZWFjaChjcC5jb25jYXQuYXBwbHkoW10sY3ApLGZ1
bmN0aW9uKGEsYil7Yi5pbmRleE9mKCJtYXJnaW4iKSYmKGYuZnguc3RlcFtiXT1mdW5jdGlvbihh
KXtmLnN0eWxlKGEuZWxlbSxiLE1hdGgubWF4KDAsYS5ub3cpK2EudW5pdCl9KX0pLGYuZXhwciYm
Zi5leHByLmZpbHRlcnMmJihmLmV4cHIuZmlsdGVycy5hbmltYXRlZD1mdW5jdGlvbihhKXtyZXR1
cm4gZi5ncmVwKGYudGltZXJzLGZ1bmN0aW9uKGIpe3JldHVybiBhPT09Yi5lbGVtfSkubGVuZ3Ro
fSk7dmFyIGN2LGN3PS9edCg/OmFibGV8ZHxoKSQvaSxjeD0vXig/OmJvZHl8aHRtbCkkL2k7Imdl
dEJvdW5kaW5nQ2xpZW50UmVjdCJpbiBjLmRvY3VtZW50RWxlbWVudD9jdj1mdW5jdGlvbihhLGIs
YyxkKXt0cnl7ZD1hLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpfWNhdGNoKGUpe31pZighZHx8IWYu
Y29udGFpbnMoYyxhKSlyZXR1cm4gZD97dG9wOmQudG9wLGxlZnQ6ZC5sZWZ0fTp7dG9wOjAsbGVm
dDowfTt2YXIgZz1iLmJvZHksaD1jeShiKSxpPWMuY2xpZW50VG9wfHxnLmNsaWVudFRvcHx8MCxq
PWMuY2xpZW50TGVmdHx8Zy5jbGllbnRMZWZ0fHwwLGs9aC5wYWdlWU9mZnNldHx8Zi5zdXBwb3J0
LmJveE1vZGVsJiZjLnNjcm9sbFRvcHx8Zy5zY3JvbGxUb3AsbD1oLnBhZ2VYT2Zmc2V0fHxmLnN1
cHBvcnQuYm94TW9kZWwmJmMuc2Nyb2xsTGVmdHx8Zy5zY3JvbGxMZWZ0LG09ZC50b3Aray1pLG49
ZC5sZWZ0K2wtajtyZXR1cm57dG9wOm0sbGVmdDpufX06Y3Y9ZnVuY3Rpb24oYSxiLGMpe3ZhciBk
LGU9YS5vZmZzZXRQYXJlbnQsZz1hLGg9Yi5ib2R5LGk9Yi5kZWZhdWx0VmlldyxqPWk/aS5nZXRD
b21wdXRlZFN0eWxlKGEsbnVsbCk6YS5jdXJyZW50U3R5bGUsaz1hLm9mZnNldFRvcCxsPWEub2Zm
c2V0TGVmdDt3aGlsZSgoYT1hLnBhcmVudE5vZGUpJiZhIT09aCYmYSE9PWMpe2lmKGYuc3VwcG9y
dC5maXhlZFBvc2l0aW9uJiZqLnBvc2l0aW9uPT09ImZpeGVkIilicmVhaztkPWk/aS5nZXRDb21w
dXRlZFN0eWxlKGEsbnVsbCk6YS5jdXJyZW50U3R5bGUsay09YS5zY3JvbGxUb3AsbC09YS5zY3Jv
bGxMZWZ0LGE9PT1lJiYoays9YS5vZmZzZXRUb3AsbCs9YS5vZmZzZXRMZWZ0LGYuc3VwcG9ydC5k
b2VzTm90QWRkQm9yZGVyJiYoIWYuc3VwcG9ydC5kb2VzQWRkQm9yZGVyRm9yVGFibGVBbmRDZWxs
c3x8IWN3LnRlc3QoYS5ub2RlTmFtZSkpJiYoays9cGFyc2VGbG9hdChkLmJvcmRlclRvcFdpZHRo
KXx8MCxsKz1wYXJzZUZsb2F0KGQuYm9yZGVyTGVmdFdpZHRoKXx8MCksZz1lLGU9YS5vZmZzZXRQ
YXJlbnQpLGYuc3VwcG9ydC5zdWJ0cmFjdHNCb3JkZXJGb3JPdmVyZmxvd05vdFZpc2libGUmJmQu
b3ZlcmZsb3chPT0idmlzaWJsZSImJihrKz1wYXJzZUZsb2F0KGQuYm9yZGVyVG9wV2lkdGgpfHww
LGwrPXBhcnNlRmxvYXQoZC5ib3JkZXJMZWZ0V2lkdGgpfHwwKSxqPWR9aWYoai5wb3NpdGlvbj09
PSJyZWxhdGl2ZSJ8fGoucG9zaXRpb249PT0ic3RhdGljIilrKz1oLm9mZnNldFRvcCxsKz1oLm9m
ZnNldExlZnQ7Zi5zdXBwb3J0LmZpeGVkUG9zaXRpb24mJmoucG9zaXRpb249PT0iZml4ZWQiJiYo
ays9TWF0aC5tYXgoYy5zY3JvbGxUb3AsaC5zY3JvbGxUb3ApLGwrPU1hdGgubWF4KGMuc2Nyb2xs
TGVmdCxoLnNjcm9sbExlZnQpKTtyZXR1cm57dG9wOmssbGVmdDpsfX0sZi5mbi5vZmZzZXQ9ZnVu
Y3Rpb24oYSl7aWYoYXJndW1lbnRzLmxlbmd0aClyZXR1cm4gYT09PWI/dGhpczp0aGlzLmVhY2go
ZnVuY3Rpb24oYil7Zi5vZmZzZXQuc2V0T2Zmc2V0KHRoaXMsYSxiKX0pO3ZhciBjPXRoaXNbMF0s
ZD1jJiZjLm93bmVyRG9jdW1lbnQ7aWYoIWQpcmV0dXJuIG51bGw7aWYoYz09PWQuYm9keSlyZXR1
cm4gZi5vZmZzZXQuYm9keU9mZnNldChjKTtyZXR1cm4gY3YoYyxkLGQuZG9jdW1lbnRFbGVtZW50
KX0sZi5vZmZzZXQ9e2JvZHlPZmZzZXQ6ZnVuY3Rpb24oYSl7dmFyIGI9YS5vZmZzZXRUb3AsYz1h
Lm9mZnNldExlZnQ7Zi5zdXBwb3J0LmRvZXNOb3RJbmNsdWRlTWFyZ2luSW5Cb2R5T2Zmc2V0JiYo
Yis9cGFyc2VGbG9hdChmLmNzcyhhLCJtYXJnaW5Ub3AiKSl8fDAsYys9cGFyc2VGbG9hdChmLmNz
cyhhLCJtYXJnaW5MZWZ0IikpfHwwKTtyZXR1cm57dG9wOmIsbGVmdDpjfX0sc2V0T2Zmc2V0OmZ1
bmN0aW9uKGEsYixjKXt2YXIgZD1mLmNzcyhhLCJwb3NpdGlvbiIpO2Q9PT0ic3RhdGljIiYmKGEu
c3R5bGUucG9zaXRpb249InJlbGF0aXZlIik7dmFyIGU9ZihhKSxnPWUub2Zmc2V0KCksaD1mLmNz
cyhhLCJ0b3AiKSxpPWYuY3NzKGEsImxlZnQiKSxqPShkPT09ImFic29sdXRlInx8ZD09PSJmaXhl
ZCIpJiZmLmluQXJyYXkoImF1dG8iLFtoLGldKT4tMSxrPXt9LGw9e30sbSxuO2o/KGw9ZS5wb3Np
dGlvbigpLG09bC50b3Asbj1sLmxlZnQpOihtPXBhcnNlRmxvYXQoaCl8fDAsbj1wYXJzZUZsb2F0
KGkpfHwwKSxmLmlzRnVuY3Rpb24oYikmJihiPWIuY2FsbChhLGMsZykpLGIudG9wIT1udWxsJiYo
ay50b3A9Yi50b3AtZy50b3ArbSksYi5sZWZ0IT1udWxsJiYoay5sZWZ0PWIubGVmdC1nLmxlZnQr
biksInVzaW5nImluIGI/Yi51c2luZy5jYWxsKGEsayk6ZS5jc3Moayl9fSxmLmZuLmV4dGVuZCh7
cG9zaXRpb246ZnVuY3Rpb24oKXtpZighdGhpc1swXSlyZXR1cm4gbnVsbDt2YXIgYT10aGlzWzBd
LGI9dGhpcy5vZmZzZXRQYXJlbnQoKSxjPXRoaXMub2Zmc2V0KCksZD1jeC50ZXN0KGJbMF0ubm9k
ZU5hbWUpP3t0b3A6MCxsZWZ0OjB9OmIub2Zmc2V0KCk7Yy50b3AtPXBhcnNlRmxvYXQoZi5jc3Mo
YSwibWFyZ2luVG9wIikpfHwwLGMubGVmdC09cGFyc2VGbG9hdChmLmNzcyhhLCJtYXJnaW5MZWZ0
IikpfHwwLGQudG9wKz1wYXJzZUZsb2F0KGYuY3NzKGJbMF0sImJvcmRlclRvcFdpZHRoIikpfHww
LGQubGVmdCs9cGFyc2VGbG9hdChmLmNzcyhiWzBdLCJib3JkZXJMZWZ0V2lkdGgiKSl8fDA7cmV0
dXJue3RvcDpjLnRvcC1kLnRvcCxsZWZ0OmMubGVmdC1kLmxlZnR9fSxvZmZzZXRQYXJlbnQ6ZnVu
Y3Rpb24oKXtyZXR1cm4gdGhpcy5tYXAoZnVuY3Rpb24oKXt2YXIgYT10aGlzLm9mZnNldFBhcmVu
dHx8Yy5ib2R5O3doaWxlKGEmJiFjeC50ZXN0KGEubm9kZU5hbWUpJiZmLmNzcyhhLCJwb3NpdGlv
biIpPT09InN0YXRpYyIpYT1hLm9mZnNldFBhcmVudDtyZXR1cm4gYX0pfX0pLGYuZWFjaCh7c2Ny
b2xsTGVmdDoicGFnZVhPZmZzZXQiLHNjcm9sbFRvcDoicGFnZVlPZmZzZXQifSxmdW5jdGlvbihh
LGMpe3ZhciBkPS9ZLy50ZXN0KGMpO2YuZm5bYV09ZnVuY3Rpb24oZSl7cmV0dXJuIGYuYWNjZXNz
KHRoaXMsZnVuY3Rpb24oYSxlLGcpe3ZhciBoPWN5KGEpO2lmKGc9PT1iKXJldHVybiBoP2MgaW4g
aD9oW2NdOmYuc3VwcG9ydC5ib3hNb2RlbCYmaC5kb2N1bWVudC5kb2N1bWVudEVsZW1lbnRbZV18
fGguZG9jdW1lbnQuYm9keVtlXTphW2VdO2g/aC5zY3JvbGxUbyhkP2YoaCkuc2Nyb2xsTGVmdCgp
OmcsZD9nOmYoaCkuc2Nyb2xsVG9wKCkpOmFbZV09Z30sYSxlLGFyZ3VtZW50cy5sZW5ndGgsbnVs
bCl9fSksZi5lYWNoKHtIZWlnaHQ6ImhlaWdodCIsV2lkdGg6IndpZHRoIn0sZnVuY3Rpb24oYSxj
KXt2YXIgZD0iY2xpZW50IithLGU9InNjcm9sbCIrYSxnPSJvZmZzZXQiK2E7Zi5mblsiaW5uZXIi
K2FdPWZ1bmN0aW9uKCl7dmFyIGE9dGhpc1swXTtyZXR1cm4gYT9hLnN0eWxlP3BhcnNlRmxvYXQo
Zi5jc3MoYSxjLCJwYWRkaW5nIikpOnRoaXNbY10oKTpudWxsfSxmLmZuWyJvdXRlciIrYV09ZnVu
Y3Rpb24oYSl7dmFyIGI9dGhpc1swXTtyZXR1cm4gYj9iLnN0eWxlP3BhcnNlRmxvYXQoZi5jc3Mo
YixjLGE/Im1hcmdpbiI6ImJvcmRlciIpKTp0aGlzW2NdKCk6bnVsbH0sZi5mbltjXT1mdW5jdGlv
bihhKXtyZXR1cm4gZi5hY2Nlc3ModGhpcyxmdW5jdGlvbihhLGMsaCl7dmFyIGksaixrLGw7aWYo
Zi5pc1dpbmRvdyhhKSl7aT1hLmRvY3VtZW50LGo9aS5kb2N1bWVudEVsZW1lbnRbZF07cmV0dXJu
IGYuc3VwcG9ydC5ib3hNb2RlbCYmanx8aS5ib2R5JiZpLmJvZHlbZF18fGp9aWYoYS5ub2RlVHlw
ZT09PTkpe2k9YS5kb2N1bWVudEVsZW1lbnQ7aWYoaVtkXT49aVtlXSlyZXR1cm4gaVtkXTtyZXR1
cm4gTWF0aC5tYXgoYS5ib2R5W2VdLGlbZV0sYS5ib2R5W2ddLGlbZ10pfWlmKGg9PT1iKXtrPWYu
Y3NzKGEsYyksbD1wYXJzZUZsb2F0KGspO3JldHVybiBmLmlzTnVtZXJpYyhsKT9sOmt9ZihhKS5j
c3MoYyxoKX0sYyxhLGFyZ3VtZW50cy5sZW5ndGgsbnVsbCl9fSksYS5qUXVlcnk9YS4kPWYsdHlw
ZW9mIGRlZmluZT09ImZ1bmN0aW9uIiYmZGVmaW5lLmFtZCYmZGVmaW5lLmFtZC5qUXVlcnkmJmRl
ZmluZSgianF1ZXJ5IixbXSxmdW5jdGlvbigpe3JldHVybiBmfSl9KSh3aW5kb3cpOw=="
type="text/javascript"></script>
<!-- jQuery 1.7.2 min }}} -->
<script type="text/javascript">
$(document).ready(function() {
	$(function(){
		$("dt").addClass("sized");
		$("dl").each(function() {
			var dlm = 0;
			$(this).find("dt").each(function() {
				if($(this).width() > dlm)
					dlm = $(this).width();
			});
			$(this).find("dt").width(dlm);
		});
	});
});
</script>
<!-- s:HILITE {{{ -->
<script type="text/javascript">
$(document).ready(function() {
	$(function(){
		$('pre.highlight').each(function(i, e) {hljs.highlightBlock(e)});
	});
});
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

/* dl styling */
dt:after {
	content: "\21B4";
	padding: 0 1em;
}

dt.sized {
	float: left;
}

dt.sized:after {
	content: "";
	padding: 0 0 0 1em; /* overriding here, thus explicit */
}

dt.sized + dd:before {
	content: "\2192";
	padding-right: 1em;
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
