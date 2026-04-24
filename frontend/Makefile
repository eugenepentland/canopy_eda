.PHONY: build dev clean

build:
	gleam run -m lustre/dev build eda_spa \
		--outdir=priv/static --no-html=true --no-tailwind=true --minify=true

dev:
	gleam run -m lustre/dev build eda_spa \
		--outdir=priv/static --no-html=true --no-tailwind=true --minify=false

clean:
	rm -rf build priv/static/eda_spa.js
