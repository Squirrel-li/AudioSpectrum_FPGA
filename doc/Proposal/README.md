# DE2-115 Audio Proposal Report

## 編譯需求
- XeLaTeX（TeX Live 或 MiKTeX）
- biber（搭配 biblatex）
- 專案內已附 `標楷體.ttf` 與 `微軟正黑體.ttf`

## 使用
```bash
make
```

`make` 會依序執行：

```bash
xelatex -shell-escape -interaction=nonstopmode main.tex
biber main
xelatex -shell-escape -interaction=nonstopmode main.tex
```

## 結構
- `main.tex`：主文件與格式設定
- `sections/`：報告章節
- `images/`：報告圖檔
- `refs.bib`：文獻庫（biber）
- `latexmkrc`、`Makefile`：自動編譯設定

內容應與根目錄 `README.md`、`DE2_115_AUDIO_SPEC.md`、`MODULE_REFERENCE.md` 的目前 RTL 行為保持一致。
