{_mk_func, compile-coffeescript, compile-livescript, xpression-to-body} = require \..
{plv8x-sql,operators-sql} = require \./sql

module.exports = (drop, cascade, done) ->
  if typeof drop is \function
    done = drop
    drop = false

  rows <~ @query "select version()"
  @conn
    ..query plv8x-sql drop, cascade

    [_, pg_version] = rows.0.version.match /^PostgreSQL ([\d\.]+)/
    if pg_version >= \9.1.0
      ..query '''
DO $$ BEGIN
    CREATE EXTENSION IF NOT EXISTS plv8;
EXCEPTION WHEN OTHERS THEN END; $$;
DO $$ BEGIN
    CREATE EXTENSION IF NOT EXISTS plls;
EXCEPTION WHEN OTHERS THEN END; $$;
'''
    else
      /* translate this from perl using shelljs
      my $dir = `pg_config --sharedir`;
      chomp $dir;
      use File::Glob qw(bsd_glob);
      my @init_files = sort { $b cmp $a } bsd_glob("$dir/contrib/plv8*.sql");
      if (@init_files > 1) {
          warn "==> more than one version of plv8 found: ".join(',',@init_files);
      }
      eval {
          $self->{dbh}->do(scalar read_file($init_files[0]));
      };
      $self->{dbh}->do('rollback') if $self->{dbh}->err;
      */

    if pg_version < \9.2.0
      ..query '''
DO $$ BEGIN
    CREATE FUNCTION plv8x.json_syntax_check(src text) RETURNS boolean AS '
        try { JSON.parse(src); return true; } catch (e) { return false; }
    ' LANGUAGE plv8 IMMUTABLE;
EXCEPTION WHEN OTHERS THEN END; $$;

DO $$ BEGIN
    CREATE DOMAIN plv8x.json AS text CHECK ( plv8x.json_syntax_check(VALUE) );
EXCEPTION WHEN OTHERS THEN END; $$;
'''
    else
      ..query '''
DO $$ BEGIN
    CREATE DOMAIN plv8x.json AS json;
EXCEPTION WHEN OTHERS THEN END; $$;
'''
  @conn
    ..query _mk_func \plv8x.boot {} \void _boot
    ..query _mk_func \plv8x.eval {str: \text} \plv8x.json _eval
    ..query _mk_func \plv8x.apply {str: \text, args: \plv8x.json} \plv8x.json _apply
    ..query _mk_func \plv8x.json_eval {code: \text} \plv8x.json _mk_json_eval(0), {+cascade, +boot}
    ..query _mk_func \plv8x.json_eval {data: \plv8x.json, code: \text} \plv8x.json _mk_json_eval(-1), {+cascade, +boot}
    ..query _mk_func \plv8x.json_eval {code: \text, data: \plv8x.json} \plv8x.json _mk_json_eval(1), {+cascade, +boot}
    ..query _mk_func \plv8x.json_eval_ls {code: \text} \plv8x.json _mk_json_eval_ls(0), {+cascade, +boot}
    ..query _mk_func \plv8x.json_eval_ls {data: \plv8x.json, code: \text} \plv8x.json _mk_json_eval_ls(-1), {+cascade, +boot}
    ..query _mk_func \plv8x.json_eval_ls {code: \text, data: \plv8x.json} \plv8x.json _mk_json_eval_ls(1), {+cascade, +boot}
    ..query operators-sql!
    r = ..query "select plv8x.boot()"
    r.on \end done

_eval = (str) -> eval str

_apply = (func, args) ->
  func = "(function() {return (#func);})()"
  eval func .apply null args

_require = (name) ->
  plv8.elog DEBUG, \require name, JSON.stringify {plv8x.require-stack, plv8x.global}
  return plv8x.global[name] if plv8x.global[name]?

  exclude = if plv8x.require-stack.length
    """where name not in (#{plv8x.require-stack.map(-> "'#it'").join \,})"""
  else
    ""

  res = plv8.execute "select name, code from plv8x.code #exclude", []
  x = {}
  err = ''
  for {code,name:bundle} in res
    plv8x.require-stack.push bundle
    try
      loader = """
(function() {
    var module = {exports: {}};
    var context = {};
    var require = function(name) {
      if (name === '#name') {
        throw new Error('Cannot find module "#name"');
      }
      return plv8x.require(name);
    };
    (function() { #code }).apply(context);
    if (module.exports.require)
      return module.exports.require('#name');
    else
      return context['#name'];
})()
"""
      if eval loader
        plv8x.require-stack.pop!
        return plv8x.global[name] = that
    catch e
      err := e
      if e isnt /Cannot find module/
        break
    plv8x.require-stack.pop!
  plv8.elog WARNING, "failed to load module #name: #err"

_mk_json_eval = (type=1) -> match type
  | (> 0) => (code, data) ->
    eval plv8x.xpression-to-body code .apply data
  | (< 0) => (data, code) ->
    eval plv8x.xpression-to-body code .apply data
  | otherwise => (code) ->
    eval plv8x.xpression-to-body code .apply @

_mk_json_eval_ls = (type=1) -> match type
  | (> 0) => (code, data) ->
    eval plv8x.xpression-to-body "~>#code" .apply data
  | (< 0) => (data, code) ->
    eval plv8x.xpression-to-body "~>#code" .apply data
  | otherwise => (code) ->
    eval plv8x.xpression-to-body "~>#code" .apply @

_boot =
  """
  function() {
    if (typeof plv8x == 'undefined')
      plv8x = {
        require: #{_require.toString!replace /(['\\])/g, '\$1'},
        xpressionToBody: #{xpression-to-body.toString!replace /(['\\])/g, '\$1'},
        compileCoffeescript: #{compile-coffeescript.toString!replace /(['\\])/g, '\$1'},
        compileLivescript: #{compile-livescript.toString!replace /(['\\])/g, '\$1'},
        requireStack: [],
        global: {}
      };
      plv8x_require = require = plv8x.require;
  }
  """

