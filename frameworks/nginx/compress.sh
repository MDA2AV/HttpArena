#!/usr/bin/env bash

DIR=/data2/static

OLDIFS=$IFS
IFS=$'\n'
for FILE in $(find $DIR -type f -iname '*.css' -o -iname '*.js' -o -iname '*.svg' -o -iname '*.json' -o -iname '*.html'); do
    echo -n "Compressing ${FILE}..."
    gzip -1 -k -f ${FILE}
    #zopfli --best=1 ${FILE}t > ${FILE}.gz
    #brotli --force ${FILE}
    echo "done."
done
IFS=$OLDIFS-1
