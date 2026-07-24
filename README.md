# BadOdinStein

An Odin rewrite of BadApplestein - tiled video encoding using PDF/image library matching.

## Building
```sh
odin build src/ -out:badodin -o:speed
```

## Usage
```sh
./badodin build /path/to/sources --color
./badodin arrange --video input.mp4
./badodin render --manifests manifests/
```
