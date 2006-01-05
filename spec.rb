#!/usr/bin/env ruby

require 'cgi'
require 'digest/md5'

class Markup
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
		template_replace(@layout, {
			:content => @content.join("\n"),
			:toc => @toc.join("\n"),
			:title => @title,
			:now => @now,
			:filename => @filename,
			})
	end
	
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
			else
				@errors << "Something weird at line: #{@line}"
			end

		end
		flush
		generate_toc
	end

	private
	def clear
		@content = []
		@toc = []
		@toc_data = []
		@state = :end
		@errors = []
		@current = []

		@layout ||= DATA.read
		@now = escape(Time.now.to_s)
		@title = "Unnamed spec ({{{{FILENAME}}}})"
		@filename = "?"
		@heading_base = 1
	end
	
	def template_replace(where, what)
		what.each do |k, v|
			where.gsub!(Regexp.new(Regexp.escape("{{{{#{k.to_s}}}}}"), Regexp::IGNORECASE), v)
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
						@toc << (" " * l) + "<ul>"
					else
						@toc << (" " * l) + "<li style='list-style-type: none;'><ul>"
					end
				end
			when 0
				# nothing
			when 1
				(level-lev).times do |i|
					l = (level - i - 1)
					if l.zero?
						@toc << (" " * l) + "</ul>"
					else
						@toc << (" " * l) + "</ul></li>"
					end
				end
			end
			level = lev
			@toc << (" " * lev) + '<li><a href="#' + key + '">' + entry + '</a></li>' unless key.nil? || entry.nil?
		end
		@toc << ""
	end

	def heading(ln)
		ar = ln.split(/^(=+\s+)/)
		if ar.size == 3 && ar[0].empty?
			sz = ar[1].strip.size
			cont = ar[2]
			id = ::Digest::MD5.hexdigest(@toc_data.size.to_s + sz.to_s + cont)
			@toc_data << [ar[1].strip.size, ar[2], id]
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
			@content << "<pre>\n" + @current.join("\n") + "\n</pre>"
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
		escape(ln)
	end

	def code_line(ln)
		escape(ln)
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
		CGI.escapeHTML(what)
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
			when /^\{\{\{/
				:code
			else
				:text
			end
		end
	end
end

if ARGV.size != 1 && ARGV.size != 2
	puts <<-EOF
		Usage: #$0 <input_file> [output_file]
	EOF
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
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="cs" lang="cs">
<head>
<meta http-equiv="content-type" content="text/html; charset=utf-8" />
<title>{{{{TITLE}}}}</title>
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
	display: block;
	padding: 1em;
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
