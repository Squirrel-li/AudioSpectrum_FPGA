
# 標準 LaTeX 專案模板

## 編譯需求
- XeLaTeX（TeX Live 或 MiKTeX）
- biber（搭配 biblatex）
- 建議安裝思源字型 Noto Serif/Sans CJK

## 使用
```bash
latexmk -xelatex -shell-escape main.tex
# 或
make
```

## 結構
- `main.tex`：主文件（設定、導入章節、文獻）
- `sections/`：章節內容（自行撰寫）
- `figs/`：圖檔（含 DFD、架構圖等）
- `tables/`：表格或 CSV（可用 pgfplotstable 引用）
- `refs.bib`：文獻庫（biber）
- `latexmkrc`、`Makefile`：自動編譯設定
