import std/[
  httpclient, tempfiles, os, strformat, tables, options,
  uri, strutils, terminal,
  asyncdispatch, times
]
import nigui
import nigui/msgbox
import jsony
import zippy/ziparchives

let
  currentDir = getCurrentDir()
  isMultiMC = fileExists(currentDir/"MultiMC.exe")
  targetDir = if isMultiMC:
    parseUri(currentDir/"instances"/"Gravitas2"/".minecraft")
  else: parseUri(currentDir)
  isCurseForge = fileExists(currentDir/"manifest.json")
  isServer = fileExists(currentDir/"server.properties")

if not isMultiMC and not isCurseForge and not isServer:
  app.init()
  var window = newWindow("Patch result")
  window.msgBox("Place this executable in your Minecraft or MultiMC root directory.   ", "Error", "Quit")
  app.quit()
  quit(1)

type
  PatchInfo = object
    project, file: Option[int32]
    url: Option[string]
  ModInfo = object
    patch: PatchInfo
    replace: seq[string]
  UpdateInfo = object
    name: string
    info: ModInfo
  UpdateList = seq[UpdateInfo]
  Mods = object
    updates: UpdateList
    removes: seq[string]
  Extras = object
    updates: seq[string]
  Meta = object
    updateSelf: string
  Patch = object
    mods: Mods
    extras: Extras
    meta: Meta

let headers = newHttpHeaders(@[
  ("userAgent", "My Patcher")
]);
var client = newHttpClient(headers = headers, maxRedirects = 0)

var updateData = client.getContent("https://raw.githubusercontent.com/ellipsi2/mcpat-update/main/update.info.json")
let data = updateData.fromJson(Patch)

proc isEmpty[T](s: seq[T]): bool =
  result = s.len <= 0

proc last[T](s: seq[T]): Option[T] =
  result = if s.isEmpty:
    none[T]()
  else:
    some(s[s.len - 1])

proc excludeLast[T](s: seq[T]): seq[T] =
  result = s[0..s.len-2]

proc getDownloadURL(p, f: int32): string =
  let url = fmt"https://www.curseforge.com/api/v1/mods/{p}/files/{f}/download"
  let head = client.head(url)
  let redirctTarget1 = client.head(head.headers["location"])
  result = decodeUrl(redirctTarget1.headers["location"])

proc makeSafeFileName(fileName: string): string =
  var safeName = ""
  
  for c in fileName:
    if c in invalidFilenameChars:
      safeName.add('_')
    else:
      safeName.add(c)
  
  return safeName

type
  Commit = object
    sha: string
  GithubBranchInfo = object
    commit: Commit

proc getLatestCommitHash(owner: string, repository: string): string =
  let
    apiUrl = "https://api.github.com/repos/" & owner & "/" & repository & "/branches/main"
    client = newHttpClient()
    content = client.getContent(apiUrl)
  # echo content
  let branchData = content.fromJson(GithubBranchInfo)
  return branchData.commit.sha

styledEcho styleBright, bgYellow, "Gravitas 2 ", bgDefault, fgCyan, "Custom Patcher ", fgWhite, "Starting..."

echo "Update `mods`"

for update in data.mods.updates:
  let extName = fmt"{update.name}.jar"
  let modFilePath = $(targetDir/"mods"/extName)

  let patch = update.info.patch
  var downloadUrl: string

  for oldFileName in update.info.replace:
    let oldFilePath = $(targetDir/"mods"/fmt"{oldFileName}.jar")
    if fileExists(oldFilePath):
      styledEcho styleBright, fgRed, "Removing ", fgWhite, "previous version... ", bgRed, oldFileName, ".jar"
      removeFile(oldFilePath)

  if fileExists(modFilePath):
    styledEcho fgYellow, "Skipping ", fgWhite, fmt"[Already exists] {extName}... "
    continue

  if patch.url.isSome:
    downloadUrl = patch.url.get
  elif patch.project.isSome and patch.file.isSome:
    let project = patch.project.get
    let file = patch.file.get
    let url = getDownloadURL(project, file)
    let uri = parseUri(url)
    let paths = uri.path.split('/')
    if paths.isEmpty:
      continue
    let filename = paths.last
    if filename.isSome and filename.get != extName:
      echo fmt"{filename.get} != {extName}! Fix it!"
      continue
    
    let p1 = paths.excludeLast.join("/")
    let p2 = encodeUrl(filename.get)
    downloadUrl = fmt"{uri.scheme}://{uri.hostname}{p1}/{p2}"

  let downloader = newHttpClient(headers = headers, maxRedirects = 0)
  styledEcho styleBright, fgGreen, "Updating ", fgWhite, bgRed, update.name, ".jar"
  downloader.downloadFile(downloadUrl, modFilePath)
  
  stdout.resetAttributes()

let sha = getLatestCommitHash("ellipsi2", "Gravitas2")

echo "update extras"
echo "Latest hash: ", sha

if fileExists($(targetDir/"custom.ver")):
  if strip(readFile($(targetDir/"custom.ver"))) == sha:
    styledEcho styleBright, fgGreen, "Is seems up to date. Skipping!"
    quit(0)

const extraFileUrl = "https://github.com/ellipsi2/Gravitas2/archive/refs/heads/main.zip"

let extraFilePath = genTempPath(fmt"{sha}_", ".tmp")

echo "Download extra files..."
let downloader = newHttpClient()
downloader.downloadFile(extraFileUrl, extraFilePath)

let tempDir = genTempPath(fmt"{sha}_", "__extras")

extractAll(extraFilePath, tempDir)

let backupDir = $(targetDir/"previous"/makeSafeFileName($now()))

createDir(backupDir)

# backup and update
for extra in data.extras.updates:
  if dirExists($(targetDir/extra)):
    styledEcho styleBright, fgGreen, fmt"'{$targetDir}/{extra}'", fgWhite, " → ", fgYellow, fmt"'{backupDir}/{extra}"
    moveDir($(targetDir/extra), backupDir/extra)
  styledEcho styleBright, fgGreen, "Updating ", fgWhite, fmt" @/{extra}"
  moveDir(tempDir/"Gravitas2-main"/extra, $(targetDir/extra))

writeFile($(targetDir/"custom.ver"), sha)

styledEcho styleBright, fgGreen, "Update Done!"
