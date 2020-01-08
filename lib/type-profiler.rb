require_relative "type-profiler/insns-def"
require_relative "type-profiler/stdlib-sigs"
require_relative "type-profiler/utils"
require_relative "type-profiler/type"
require_relative "type-profiler/method"
require_relative "type-profiler/iseq"
require_relative "type-profiler/analyzer"
require_relative "type-profiler/import"
require_relative "type-profiler/export"
require_relative "type-profiler/builtin"

module TypeProfiler
  def self.type_profile(iseq)
    # TODO: resolve file path
    scratch = Scratch.new
    setup_initial_global_env(scratch)
    main_ep, main_env = starting_state(iseq)
    scratch.merge_env(main_ep, main_env)
    _nil = Type::Instance.new(Type::Builtin[:nil])

    prologue_ctx = Context.new(nil, nil, nil, nil)
    prologue_ep = ExecutionPoint.new(prologue_ctx, -1, nil)
    prologue_env = Env.new(:top, _nil, [], [], {})
    scratch.add_callsite!(main_ep.ctx, nil, prologue_ep, prologue_env) {|ty, ep| }
    scratch.type_profile
  end

  def self.starting_state(iseq)
    cref = CRef.new(:bottom, Type::Builtin[:obj]) # object
    recv = Type::Instance.new(Type::Builtin[:obj])
    _nil = Type::Instance.new(Type::Builtin[:nil])
    ctx = Context.new(iseq, cref, nil, nil)
    ep = ExecutionPoint.new(ctx, 0, nil)
    locals = [Type::Instance.new(Type::Builtin[:nil])] * iseq.locals.size
    env = Env.new(recv, _nil, locals, [], {})

    return ep, env
  end
end
