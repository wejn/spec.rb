all: spec.html

%.html: %.txt
	./spec.rb $< $@

clean:
	rm -f *.html

watch:
	onfilechange spec.txt make
