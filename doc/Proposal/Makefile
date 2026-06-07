# Build with latexmk (XeLaTeX + biber)
all:
	latexmk -xelatex -shell-escape -interaction=nonstopmode main.tex

clean:
	latexmk -C
	rm -f *.bbl *.blg *.run.xml *.bcf

.PHONY: all clean