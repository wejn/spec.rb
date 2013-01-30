all: spec.html

%.html: %.txt spec.rb
	./spec.rb $< $@

clean:
	rm -f *.html

watch:
	onfilechange spec.txt make

push: all
	scp spec.txt spec.html wejn@platinum:www/stuff/
