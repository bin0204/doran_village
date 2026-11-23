# Builds index.html (a page a browser can open directly) from src/doran-village.html.
# The source is the body used for the claude.ai artifact: it starts with <title>, <meta>, <link>, <style>
# and has no <html>/<head>/<body>. Everything up to the first </style> goes into <head>.
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object Text.UTF8Encoding $false
$src = [IO.File]::ReadAllText("$d\src\doran-village.html", $utf8)
$i = $src.IndexOf('</style>')
if ($i -lt 0) { throw 'src/doran-village.html has no </style>' }
$i += 8
$head = '<!doctype html>' + "`n" + '<html lang="ko">' + "`n" + '<head>' + "`n" +
  '<meta charset="utf-8">' + "`n" +
  '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">' + "`n" +
  '<style>body{margin:0}[hidden]{display:none!important}img{max-width:100%}</style>' + "`n"
$out = $head + $src.Substring(0, $i) + "`n</head>`n<body>" + $src.Substring($i).TrimEnd() + "`n</body>`n</html>`n"
[IO.File]::WriteAllText("$d\index.html", $out, $utf8)
"index.html: $([Math]::Round($out.Length/1024)) KB"
