#!/bin/bash

ffmpeg -re -f lavfi -i "aevalsrc=if(eq(floor(t)\,ld(2))\,st(0\,random(4)*3000+1000))\;st(2\,floor(t)+1)\;st(1\,mod(t\,1))\;(0.6*sin(1*ld(0)*ld(1))+0.4*sin(2*ld(0)*ld(1)))*exp(-4*ld(1)) [out1]; testsrc=s=800x600,drawtext=borderw=5:fontcolor=white:fontsize=30:text='%{localtime}/%{pts\:hms}':x=\(w-text_w\)/2:y=\(h-text_h-line_h\)/2 [out0]" \
-acodec aac -vcodec h264 -strict -2 -pix_fmt yuv420p -profile:v baseline -level 3.0 \
$@