all:
	xelatex -shell-escape -interaction=nonstopmode main.tex
	biber main
	xelatex -shell-escape -interaction=nonstopmode main.tex

clean:
	rm -f *.aux *.bbl *.bcf *.blg *.fdb_latexmk *.fls *.log *.out *.run.xml *.toc

.PHONY: all clean
