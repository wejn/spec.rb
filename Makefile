all: spec.html

%.html: %.txt spec.rb
	./spec.rb $< $@

clean:
	rm -f *.html

watch:
	onfilechange 'spec.*' './spec.rb spec.txt ~/download/spec.html'

push: all
	scp spec.txt spec.html wejn@platinum:www/stuff/

togithub: push
	test -d .git
	svn2git --rebase
	git push origin master
