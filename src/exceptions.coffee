
# pull in external modules
_ = require '../vendor/_.js'
{trace,vtrace,error,debug} = require './logging'
{JavaObject} = require './java_object'

"use strict"

# things assigned to root will be available outside this module
root = exports ? window.exceptions ?= {}

class root.HaltException
  constructor: (@exit_code) ->
  toplevel_catch_handler: () ->
    error "\nExited with code #{@exit_code}" unless @exit_code is 0

root.ReturnException = 'RETURNEXCEPTION'

class root.YieldException
  constructor: (@condition) ->

class root.YieldIOException extends root.YieldException
  # empty class

class root.JavaException
  constructor: (@exception) ->

  method_catch_handler: (rs, method, top_of_stack) ->
    cf = rs.curr_frame()
    if not top_of_stack and method.has_bytecode
      cf.pc -= 3  # rewind the invoke opcode
      --cf.pc until cf.pc <= 0 or method.code.opcodes[cf.pc]?.name.match /^invoke/

    # Switch the native frame's runner to its error handler, if it exists.
    if cf.native
      if cf.error?
        cf.runner = ()=>cf.error @
        return true
      return false

    exception_handlers = method.code?.exception_handlers
    ecls = @exception.cls
    handler = _.find exception_handlers, (eh) ->
      # XXX: Kludge. If the class is not loaded, then it is not possible for this to be the correct exception handler
      eh.start_pc <= cf.pc < eh.end_pc and method.cls.loader.get_loaded_class(eh.catch_type, true)? and
        (eh.catch_type == "<any>" or ecls.is_castable rs, method.cls.loader.get_loaded_class(eh.catch_type))
    if handler?
      debug "caught #{@exception.cls.toClassString()} in #{method.full_signature()} as subclass of #{handler.catch_type}"
      cf.stack = []  # clear out anything on the stack; it was made during the try block
      rs.push @exception
      cf.pc = handler.handler_pc
      return true
    # abrupt method invocation completion
    debug "exception not caught, terminating #{method.full_signature()}"
    return false

  toplevel_catch_handler: (rs) ->
    debug "\nUncaught #{@exception.cls.toClassString()}"
    msg = @exception.get_field rs, 'Ljava/lang/Throwable;detailMessage'
    debug "\t#{msg.jvm2js_str()}" if msg?
    rs.show_state()
    rs.push2 rs.curr_thread, @exception
    thread_cls = rs.get_bs_class('Ljava/lang/Thread;')
    rs.method_lookup(thread_cls,
      { class: 'Ljava/lang/Thread;'
      sig: 'dispatchUncaughtException(Ljava/lang/Throwable;)V'} ).setup_stack(rs)


# Simulate the throwing of a Java exception with message :msg. Not very DRY --
# code here is essentially copied from the opcodes themselves -- but
# constructing the opcodes manually is inelegant too.
root.java_throw = (rs, cls, msg) ->
  method_spec = sig: '<init>(Ljava/lang/String;)V'
  v = new JavaObject rs, cls  # new
  rs.push_array([v,v,rs.init_string msg]) # dup, ldc
  my_sf = rs.curr_frame()
  rs.method_lookup(cls, method_spec).setup_stack(rs) # invokespecial
  my_sf.runner = ->
    if my_sf.method.has_bytecode
      my_sf.runner = (-> my_sf.method.run_bytecode(rs))  # don't re-throw the exception
    else
      my_sf.runner = null
    throw (new root.JavaException(rs.pop())) # athrow
  throw root.ReturnException
