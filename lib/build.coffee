pr = require 'bluebird'
fs = pr.promisifyAll require 'fs'
path = require 'path'
mkdirp = require 'mkdirp'
pug = require 'pug'
coffeescript = require 'coffee-script'
uglify = require 'uglify-js'
styl = require 'stylus'
svgo = require 'svgo'
uglifycss = require 'uglifycss'
htmlmin = require 'html-minifier'
yaml = require 'js-yaml'
{ execAsync } = pr.promisifyAll require 'child_process'

log = ->
  if self.verbose
    console.log.apply(null, arguments)

module.exports = self =
  prod: process.env.NODE_ENV
  dist: "#{__dirname}/../dist"
  verbose: false
  vars:
    src: {}
    filters:
      inject: (text, options) ->
        log 'inject:', text.replace(/\n/g, '').slice(0, 60) + '...', options
        { ext, srcname } = self.parsename options.filename
        if not text
          # we need to read from ... something
          if ext isnt 'pug'
            out = self.vars.src[srcname]
          else
            if not options.file
              throw new Error ":inject() is missing 'file' attribute: #{options.filename}"
            { srcname, ext } = self.parsename options.file
            out = self.vars.src[srcname] or
              throw new Error "no content found for #{srcname}"
        else
          if ext is 'pug'
            ext = options.ext
          if ext is 'svg'
            out = self.vars.src[srcname] or
              throw new Error "no content found for #{srcname}"
          else
            out = self.exts[ext].call(self, text) or
              throw new Error "no content found for extension #{ext}"

        if ext in ['js', 'coffee']
          "<script>\n#{out}\n</script>"
        else if ext in ['css', 'styl']
          "<style>\n#{out}\n</style>"
        else
          out

  # replacement for path.parse(), but in the context of this module
  parsename: (f) ->
    parts = path.parse f
    parts.ext = parts.ext.replace /^\./, ''
    parts.absfile = path.resolve @vars.basedir, f
    parts.absdir = path.resolve @vars.basedir
    parts.srcname = parts.absfile.replace(new RegExp(parts.absdir, 'i'), '').replace(/^\//, '')
    parts

  pug: (file, outfile) ->
    log 'pug:', file, outfile, @vars.basedir, @dist
    mkdirp.sync @dist
    @vars.pretty = not @prod
    fs.writeFileAsync "#{@dist}/#{outfile}", pug.renderFile file, @vars

  # call as either transform(filename) or transform(ext, text)
  transform: (args...) ->
    if args.length is 1
      filename = args[0]
      s = fs.readFileSync filename, 'utf8'
      { ext } = @parsename filename
    else
      [ ext, s ] = args
      filename = 'inline'

    if ext is 'svg'
      @exts[ext].call(this, s, filename)
    else
      try
        pr.resolve @exts[ext].call(this, s, filename)
      catch err
        console.error 'transform error:', args
        throw err

  # each of these takes the same two arguments:
  # - some text content
  # - the filename, purely for reference (sourcemaps, etc)
  # all of them are syncronous, EXCEPT for:
  # - svg
  exts:
    js: (s) ->
      if @prod
        r = uglify.minify s
        throw r.error if r.error
        r.code
      else
        s

    coffee: (s, filename) ->
      js = coffeescript.compile s,
        bare: true
        filename: filename
        map: not @prod
        inlineMap: not @prod
      @exts.js js

    css: (s) ->
      if @prod
        uglifycss.processString s
      else
        s

    styl: (s) -> @exts.css styl.render s

    svg: (s, filename) ->
      new pr (resolve) ->
        { name } = self.parsename filename

        plugins = []
        plugins.push
          addClassesToSVGElement:
            classNames: [name]
        plugins.push
          removeDimensions: true

        new svgo { plugins }
          .optimize s, (svg) ->
            resolve svg.data

    html: (s) ->
      if @prod
        htmlmin.minify(s)
      else
        s

    json: (s) -> JSON.parse s

    yml: (s) -> yaml.load s

  crawl: (root, handlePug) ->
    @vars.basedir = path.resolve root

    execAsync("find '#{@vars.basedir}' -type f -print0").then (stdout) =>
      pug_files = []
      other_files = []

      stdout.split('\0').forEach (f) =>
        return unless f
        { name, ext, srcname } = @parsename f
        if name.match(/^_/)
          log "skip: #{f}"
          @vars.src[srcname] = null
        else if ext is 'pug'
          pug_files.push f
          @vars.src[srcname] = null
        else if @exts[ext]
          other_files.push f

      pr.each other_files, (f) =>
        log 'reading:', f
        { srcname } = @parsename f
        unless @vars.src[srcname]
          @transform(f).then (out) =>
            @vars.src[srcname] = out
      .then =>
        if handlePug
          pr.each pug_files, (f) =>
            outfile = f.replace /\.pug$/i, '.html'
            { srcname } = @parsename outfile
            @pug f, srcname
    .catch console.error

  self: (testPug) ->
    @crawl("#{__dirname}/../src").then =>
      if testPug
        @crawl("#{__dirname}/../test", true)