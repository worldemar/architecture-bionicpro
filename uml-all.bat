docker run --rm ^
    -v .:/sources ^
    -v C:\windows\fonts:/usr/local/share/fonts ^
    -v C:\Users\wolde\AppData\Local\Microsoft\Windows\Fonts:/var/lib/jetty/.fonts ^
    -e PLANTUML_INCLUDE_PATH=/sources/ ^
    -e PLANTUML_LIMIT_SIZE=16384 ^
    plantuml/plantuml:1.2025 ^
    -nbthread auto ^
    -progress ^
    -tpng ^
    /sources/**/*.puml

@REM server can be started with

@REM docker run -d -p 127.0.0.1:8888:8080 -e PLANTUML_LIMIT_SIZE=16384 -e PLANTUML_INCLUDE_PATH=. -v C:\windows\fonts:/usr/local/share/fonts -v C:\Users\wolde\AppData\Local\Microsoft\Windows\Fonts:/var/lib/jetty/.fonts --name plantuml-server plantuml/plantuml-server:jetty
