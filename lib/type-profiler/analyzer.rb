module TypeProfiler
  class CRef
    include Utils::StructuralEquality

    def initialize(outer, klass)
      @outer = outer
      @klass = klass
      # flags
      # scope_visi (= method_visi * module_func_flag)
      # refinements
    end

    def extend(klass)
      CRef.new(self, klass)
    end

    attr_reader :outer, :klass

    def pretty_print(q)
      q.text "CRef["
      q.pp @klass
      q.text "]"
    end
  end

  class Context
    include Utils::StructuralEquality

    def initialize(iseq, cref, singleton, mid)
      @iseq = iseq
      @cref = cref
      @singleton = singleton
      @mid = mid
    end

    attr_reader :iseq, :cref, :singleton, :mid
  end

  class ExecutionPoint
    include Utils::StructuralEquality

    def initialize(ctx, pc, outer)
      @ctx = ctx
      @pc = pc
      @outer = outer
    end

    def key
      [@ctx.iseq, @pc, @sig]
    end

    attr_reader :ctx, :pc, :outer

    def jump(pc)
      ExecutionPoint.new(@ctx, pc, @outer)
    end

    def next
      ExecutionPoint.new(@ctx, @pc + 1, @outer)
    end

    def source_location
      iseq = @ctx.iseq
      if iseq
        iseq.source_location(@pc)
      else
        "<builtin>"
      end
    end
  end

  class Env
    include Utils::StructuralEquality

    def initialize(recv_ty, blk_ty, locals, stack, type_params)
      @recv_ty = recv_ty
      @blk_ty = blk_ty
      @locals = locals
      @stack = stack
      @type_params = type_params
    end

    attr_reader :recv_ty, :blk_ty, :locals, :stack, :type_params

    def merge(other)
      raise if @locals.size != other.locals.size
      raise if @stack.size != other.stack.size
      recv_ty = @recv_ty.union(other.recv_ty)
      blk_ty = @blk_ty.union(other.blk_ty)
      locals = @locals.zip(other.locals).map {|ty1, ty2| ty1.union(ty2) }
      stack = @stack.zip(other.stack).map {|ty1, ty2| ty1.union(ty2) }
      if @type_params
        raise if !other.type_params
        if @type_params == other.type_params
          type_params = @type_params
        else
          type_params = @type_params.internal_hash.dup
          other.type_params.internal_hash.each do |id, elems|
            elems2 = type_params[id]
            if elems2
              type_params[id] = elems.union(elems2) if elems != elems2
            else
              type_params[id] = elems
            end
          end
          type_params = Utils::HashWrapper.new(type_params)
        end
      else
        raise if other.type_params
      end
      Env.new(recv_ty, blk_ty, locals, stack, type_params)
    end

    def push(*tys)
      tys.each do |ty|
        raise "nil cannot be pushed to the stack" if ty.nil?
        ty.each_child do |ty|
          raise "Array cannot be pushed to the stack" if ty.is_a?(Type::Array)
          raise "Hash cannot be pushed to the stack" if ty.is_a?(Type::Hash)
        end
      end
      Env.new(@recv_ty, @blk_ty, @locals, @stack + tys, @type_params)
    end

    def pop(n)
      stack = @stack.dup
      tys = stack.pop(n)
      nenv = Env.new(@recv_ty, @blk_ty, @locals, stack, @type_params)
      return nenv, tys
    end

    def setn(i, ty)
      stack = Utils.array_update(@stack, -i, ty)
      Env.new(@recv_ty, @blk_ty, @locals, stack, @type_params)
    end

    def topn(i)
      push(@stack[-i - 1])
    end

    def get_local(idx)
      @locals[idx]
    end

    def local_update(idx, ty)
      Env.new(@recv_ty, @blk_ty, Utils.array_update(@locals, idx, ty), @stack, @type_params)
    end

    def deploy_array_type(alloc_site, elems, base_ty)
      local_ty = Type::LocalArray.new(alloc_site, base_ty)
      type_params = Utils::HashWrapper.new(@type_params.internal_hash.merge({ alloc_site => elems }))
      nenv = Env.new(@recv_ty, @blk_ty, @locals, @stack, type_params)
      return nenv, local_ty
    end

    def deploy_hash_type(alloc_site, elems, base_ty)
      local_ty = Type::LocalHash.new(alloc_site, base_ty)
      type_params = Utils::HashWrapper.new(@type_params.internal_hash.merge({ alloc_site => elems }))
      nenv = Env.new(@recv_ty, @blk_ty, @locals, @stack, type_params)
      return nenv, local_ty
    end

    def get_container_elem_types(id)
      @type_params.internal_hash[id]
    end

    def update_container_elem_types(id, elems)
      type_params = Utils::HashWrapper.new(@type_params.internal_hash.merge({ id => elems }))
      Env.new(@recv_ty, @blk_ty, @locals, @stack, type_params)
    end

    def inspect
      "Env[recv_ty:#{ @recv_ty.inspect }, blk_ty:#{ @blk_ty.inspect }, locals:#{ @locals.inspect }, stack:#{ @stack.inspect }, type_params:#{ @type_params.internal_hash.inspect }]"
    end
  end

  class Scratch
    def inspect
      "#<Scratch>"
    end

    def initialize
      @worklist = Utils::WorkList.new

      @ep2env = {}

      @class_defs = {}

      @callsites, @return_envs, @sig_fargs, @sig_ret, @yields = {}, {}, {}, {}, {}
      @ivar_table = VarTable.new
      @cvar_table = VarTable.new
      @gvar_table = VarTable.new

      @errors = []
      @backward_edges = {}
    end

    attr_reader :return_envs

    def get_env(ep)
      @ep2env[ep]
    end

    def merge_env(ep, env)
      # TODO: this is wrong; it include not only proceeds but also indirect propagation like out-of-block variable modification
      #add_edge(ep, @ep)
      env2 = @ep2env[ep]
      if env2
        nenv = env2.merge(env)
        if !nenv.eql?(env2) && !@worklist.member?(ep)
          @worklist.insert(ep.key, ep)
        end
        @ep2env[ep] = nenv
      else
        @worklist.insert(ep.key, ep)
        @ep2env[ep] = env
      end
    end

    attr_reader :class_defs

    class ClassDef # or ModuleDef
      def initialize(kind, name, superclass)
        @kind = kind
        @superclass = superclass
        @included_modules = []
        @extended_modules = []
        @name = name
        @consts = {}
        @methods = {}
        @singleton_methods = {}
      end

      attr_reader :kind, :included_modules, :name, :methods, :superclass

      def include_module(mod)
        # XXX: need to check if mod is already included by the ancestors?
        unless @included_modules.include?(mod)
          @included_modules << mod
        end
      end

      def extend_module(mod)
        # XXX: need to check if mod is already included by the ancestors?
        unless @extended_modules.include?(mod)
          @extended_modules << mod
        end
      end

      def get_constant(name)
        @consts[name] || Type.any # XXX: warn?
      end

      def add_constant(name, ty)
        if @consts[name]
          # XXX: warn!
        end
        @consts[name] = ty
      end

      def get_method(mid)
        if @methods.key?(mid)
          @methods[mid]
        else
          @included_modules.reverse_each do |mod|
            mhtd = mod.get_method(mid)
            return mhtd if mhtd
          end
          nil
        end
      end

      def add_method(mid, mdef)
        @methods[mid] ||= Utils::MutableSet.new
        @methods[mid] << mdef
        # Need to restart...?
      end

      def get_singleton_method(mid)
        if @singleton_methods.key?(mid)
          @singleton_methods[mid]
        else
          @extended_modules.reverse_each do |mod|
            mhtd = mod.get_method(mid)
            return mhtd if mhtd
          end
          nil
        end
      end

      def add_singleton_method(mid, mdef)
        @singleton_methods[mid] ||= Utils::MutableSet.new
        @singleton_methods[mid] << mdef
      end
    end

    def include_module(including_mod, included_mod)
      including_mod = @class_defs[including_mod.idx]
      included_mod = @class_defs[included_mod.idx]
      if included_mod && included_mod.kind == :module
        including_mod.include_module(included_mod)
      else
        warn "including something that is not a module"
      end
    end

    def extend_module(extending_mod, extended_mod)
      extending_mod = @class_defs[extending_mod.idx]
      extended_mod = @class_defs[extended_mod.idx]
      if extended_mod && extended_mod.kind == :module
        extending_mod.extend_module(extended_mod)
      else
        warn "including something that is not a module"
      end
    end

    def new_class(cbase, name, superclass)
      if cbase && cbase.idx != 0
        show_name = "#{ @class_defs[cbase.idx].name }::#{ name }"
      else
        show_name = name.to_s
      end
      idx = @class_defs.size
      if superclass
        if superclass == :__root__
          superclass_idx = superclass = nil
        else
          superclass_idx = superclass.idx
        end
        @class_defs[idx] = ClassDef.new(:class, show_name, superclass_idx)
        klass = Type::Class.new(:class, idx, superclass, show_name)
        cbase ||= klass # for bootstrap
        add_constant(cbase, name, klass)
        return klass
      else
        # module
        @class_defs[idx] = ClassDef.new(:module, show_name, nil)
        mod = Type::Class.new(:module, idx, nil, show_name)
        add_constant(cbase, name, mod)
        return mod
      end
    end

    def get_class_name(klass)
      if klass == Type.any
        "???"
      else
        @class_defs[klass.idx].name
      end
    end

    def get_method(klass, mid)
      idx = klass.idx
      while idx
        class_def = @class_defs[idx]
        mthd = class_def.get_method(mid)
        # Need to be conservative to include all super candidates...?
        return mthd if mthd
        idx = class_def.superclass
      end
      nil
    end

    def get_singleton_method(klass, mid)
      idx = klass.idx
      while idx
        class_def = @class_defs[idx]
        mthd = class_def.get_singleton_method(mid)
        # Need to be conservative to include all super candidates...?
        return mthd if mthd
        idx = class_def.superclass
      end
      # fallback to methods of Class class
      get_method(Type::Builtin[:class], mid)
    end

    def get_super_method(ctx)
      idx = ctx.cref.klass.idx
      mid = ctx.mid
      idx = @class_defs[idx].superclass
      while idx
        class_def = @class_defs[idx]
        mthd = ctx.singleton ? class_def.get_singleton_method(mid) : class_def.get_method(mid)
        return mthd if mthd
        idx = class_def.superclass
      end
      nil
    end

    def get_constant(klass, name)
      if klass == Type.any
        Type.any
      elsif klass.is_a?(Type::Class)
        @class_defs[klass.idx].get_constant(name)
      else
        Type.any
      end
    end

    def search_constant(cref, name)
      while cref != :bottom
        val = get_constant(cref.klass, name)
        return val if val != Type.any
        cref = cref.outer
      end

      Type.any
    end

    def add_constant(klass, name, value)
      if klass == Type.any
        self
      else
        @class_defs[klass.idx].add_constant(name, value)
      end
    end

    def add_method(klass, mid, mdef)
      if klass == Type.any
        self # XXX warn
      else
        @class_defs[klass.idx].add_method(mid, mdef)
      end
    end

    def add_singleton_method(klass, mid, mdef)
      if klass == Type.any
        self # XXX warn
      else
        @class_defs[klass.idx].add_singleton_method(mid, mdef)
      end
    end

    def add_iseq_method(klass, mid, iseq, cref)
      add_method(klass, mid, ISeqMethodDef.new(iseq, cref, false))
    end

    def add_singleton_iseq_method(klass, mid, iseq, cref)
      add_singleton_method(klass, mid, ISeqMethodDef.new(iseq, cref, true))
    end

    def add_typed_method(recv_ty, mid, fargs, ret_ty)
      add_method(recv_ty.klass, mid, TypedMethodDef.new([[fargs, ret_ty]]))
    end

    def add_singleton_typed_method(recv_ty, mid, fargs, ret_ty)
      add_singleton_method(recv_ty.klass, mid, TypedMethodDef.new([[fargs, ret_ty]]))
    end

    def add_custom_method(klass, mid, impl)
      add_method(klass, mid, CustomMethodDef.new(impl))
    end

    def add_singleton_custom_method(klass, mid, impl)
      add_singleton_method(klass, mid, CustomMethodDef.new(impl))
    end

    def alias_method(klass, singleton, new, old)
      if klass == Type.any
        self
      else
        if singleton
          get_singleton_method(klass, old).each do |mdef|
            @class_defs[klass.idx].add_singleton_method(new, mdef)
          end
        else
          get_method(klass, old).each do |mdef|
            @class_defs[klass.idx].add_method(new, mdef)
          end
        end
      end
    end

    def add_edge(ep, next_ep)
      (@backward_edges[next_ep] ||= {})[ep] = true
    end

    def add_callsite!(callee_ctx, fargs, caller_ep, caller_env, &ctn)
      @callsites[callee_ctx] ||= {}
      @callsites[callee_ctx][caller_ep] = ctn
      merge_return_env(caller_ep) {|env| env ? env.merge(caller_env) : caller_env }

      if @sig_fargs[callee_ctx]
        @sig_fargs[callee_ctx] = @sig_fargs[callee_ctx].merge(fargs)
      else
        @sig_fargs[callee_ctx] = fargs
      end
      ret_ty = @sig_ret[callee_ctx] ||= Type.bot
      unless ret_ty.eql?(Type.bot)
        @callsites[callee_ctx].each do |caller_ep, ctn|
          ctn[ret_ty, caller_ep, @return_envs[caller_ep]] # TODO: use Union type
        end
      end
    end

    def merge_return_env(caller_ep)
      @return_envs[caller_ep] = yield @return_envs[caller_ep]
    end

    def add_return_type!(callee_ctx, ret_ty)
      @sig_ret[callee_ctx] ||= Type.bot
      @sig_ret[callee_ctx] = @sig_ret[callee_ctx].union(ret_ty)

      #@callsites[callee_ctx] ||= {} # needed?
      @callsites[callee_ctx].each do |caller_ep, ctn|
        ctn[ret_ty, caller_ep, @return_envs[caller_ep]]
      end
    end

    def add_yield!(caller_ctx, fargs, blk_ctx)
      @yields[caller_ctx] ||= Utils::MutableSet.new
      @yields[caller_ctx] << [blk_ctx, fargs]
    end

    class VarTable
      def initialize
        @read, @write = {}, {}
      end

      attr_reader :write

      def add_read!(site, ep, &ctn)
        @read[site] ||= {}
        @read[site][ep] = ctn
        @write[site] ||= Type.bot
        ctn[@write[site], ep]
      end

      def add_write!(site, ty, &ctn)
        @write[site] ||= Type.bot
        @write[site] = @write[site].union(ty)
        @read[site] ||= {}
        @read[site].each do |ep, ctn|
          ctn[ty, ep]
        end
      end
    end

    def add_ivar_read!(recv, var, ep, &ctn)
      @ivar_table.add_read!([recv, var], ep, &ctn)
    end

    def add_ivar_write!(recv, var, ty, &ctn)
      @ivar_table.add_write!([recv, var], ty, &ctn)
    end

    def add_cvar_read!(klass, var, ep, &ctn)
      @cvar_table.add_read!([klass, var], ep, &ctn)
    end

    def add_cvar_write!(klass, var, ty, &ctn)
      @cvar_table.add_write!([klass, var], ty, &ctn)
    end

    def add_gvar_read!(var, ep, &ctn)
      @gvar_table.add_read!(var, ep, &ctn)
    end

    def add_gvar_write!(var, ty, &ctn)
      @gvar_table.add_write!(var, ty, &ctn)
    end

    def error(ep, msg)
      p [ep.source_location, "[error] " + msg] if ENV["TP_DEBUG"]
      @errors << [ep, "[error] " + msg]
    end

    def warn(ep, msg)
      p [ep.source_location, "[warning] " + msg] if ENV["TP_DEBUG"]
      @errors << [ep, "[warning] " + msg]
    end

    def reveal_type(ep, msg)
      p [ep.source_location, "[p] " + msg] if ENV["TP_DEBUG"]
      @errors << [ep, "[p] " + msg]
    end

    def get_container_elem_types(env, ep, id)
      if ep.outer
        tmp_ep = ep
        tmp_ep = tmp_ep.outer while tmp_ep.outer
        env = @return_envs[tmp_ep]
      end
      env.get_container_elem_types(id)
    end

    def update_container_elem_types(env, ep, id)
      if ep.outer
        tmp_ep = ep
        tmp_ep = tmp_ep.outer while tmp_ep.outer
        merge_return_env(tmp_ep) do |menv|
          elems = menv.get_container_elem_types(id)
          elems = yield elems
          menv.update_container_elem_types(id, elems)
        end
        env
      else
        elems = env.get_container_elem_types(id)
        elems = yield elems
        env.update_container_elem_types(id, elems)
      end
    end

    def get_array_elem_type(env, ep, id, idx = nil)
      elems = get_container_elem_types(env, ep, id)

      if elems
        return elems[idx] || Type.nil if idx
        return elems.squash
      else
        Type.any
      end
    end

    def get_hash_elem_type(env, ep, id, key_ty = nil)
      elems = get_container_elem_types(env, ep, id)

      if elems
        elems[key_ty || Type.any]
      else
        Type.any
      end
    end

    def type_profile
      counter = 0
      stat_eps = Utils::MutableSet.new
      until @worklist.empty?
        counter += 1
        if counter % 1000 == 0
          puts "iter %d, remain: %d" % [counter, @worklist.size]
        end
        @ep = @worklist.deletemin
        @env = @ep2env[@ep]
        stat_eps << @ep
        step(@ep) # TODO: deletemin
      end
      RubySignatureExporter.new(
        self, @errors, @gvar_table.write, @ivar_table.write, @cvar_table.write,
        @sig_fargs, @sig_ret, @yields, @backward_edges,
      ).show(stat_eps)
    end

    def globalize_type(ty, env, ep)
      if ep.outer
        tmp_ep = ep
        tmp_ep = tmp_ep.outer while tmp_ep.outer
        env = @return_envs[tmp_ep]
      end
      ty.globalize(env, {})
    end

    def localize_type(ty, env, ep, alloc_site = AllocationSite.new(ep))
      if ep.outer
        tmp_ep = ep
        tmp_ep = tmp_ep.outer while tmp_ep.outer
        target_env = @return_envs[tmp_ep]
        target_env, ty = ty.localize(target_env, alloc_site)
        merge_return_env(tmp_ep) do |env|
          env ? env.merge(target_env) : target_env
        end
        return env, ty
      else
        return ty.localize(env, alloc_site)
      end
    end

    def step(ep)
      orig_ep = ep
      env = @ep2env[ep]
      raise "nil env" unless env

      insn, *operands = ep.ctx.iseq.insns[ep.pc]

      if ENV["TP_DEBUG"]
        p [ep.pc, ep.ctx.iseq.name, ep.source_location, insn, operands]
      end

      case insn
      when :putspecialobject
        kind, = operands
        ty = case kind
        when 1 then Type::Instance.new(Type::Builtin[:vmcore])
        when 2, 3 # CBASE / CONSTBASE
          ep.ctx.cref.klass
        else
          raise NotImplementedError, "unknown special object: #{ type }"
        end
        env = env.push(ty)
      when :putnil
        env = env.push(Type.nil)
      when :putobject, :duparray
        obj, = operands
        env, ty = localize_type(Type.guess_literal_type(obj), env, ep)
        env = env.push(ty)
      when :putstring
        str, = operands
        ty = Type::Literal.new(str, Type::Instance.new(Type::Builtin[:str]))
        env = env.push(ty)
      when :putself
        env = env.push(env.recv_ty)
      when :newarray, :newarraykwsplat
        len, = operands
        env, elems = env.pop(len)
        ty = Type::Array.new(Type::Array::Elements.new(elems), Type::Instance.new(Type::Builtin[:ary]))
        env, ty = localize_type(ty, env, ep)
        env = env.push(ty)
      when :newhash
        num, = operands
        env, tys = env.pop(num)

        ty = Type.gen_hash do |h|
          tys.each_slice(2) do |k_ty, v_ty|
            h[k_ty] = v_ty
          end
        end

        env, ty = localize_type(ty, env, ep)
        env = env.push(ty)
      when :newhashfromarray
        raise NotImplementedError, "newhashfromarray"
      when :newrange
        env, tys = env.pop(2)
        # XXX: need generics
        env = env.push(Type::Instance.new(Type::Builtin[:range]))

      when :concatstrings
        num, = operands
        env, = env.pop(num)
        env = env.push(Type::Instance.new(Type::Builtin[:str]))
      when :tostring
        env, (_ty1, _ty2,) = env.pop(2)
        env = env.push(Type::Instance.new(Type::Builtin[:str]))
      when :freezestring
        # do nothing
      when :toregexp
        _regexp_opt, str_count = operands
        env, tys = env.pop(str_count)
        # TODO: check if tys are all strings?
        env = env.push(Type::Instance.new(Type::Builtin[:regexp]))
      when :intern
        env, (ty,) = env.pop(1)
        # XXX check if ty is String
        env = env.push(Type::Instance.new(Type::Builtin[:sym]))

      when :definemethod
        mid, iseq = operands
        cref = ep.ctx.cref
        if ep.ctx.singleton
          add_singleton_iseq_method(cref.klass, mid, iseq, cref)
        else
          add_iseq_method(cref.klass, mid, iseq, cref)
        end
      when :definesmethod
        mid, iseq = operands
        env, (recv,) = env.pop(1)
        cref = ep.ctx.cref
        add_singleton_iseq_method(recv, mid, iseq, cref)
      when :defineclass
        id, iseq, flags = operands
        env, (cbase, superclass) = env.pop(2)
        case flags & 7
        when 0, 2 # CLASS / MODULE
          type = (flags & 7) == 2 ? :module : :class
          existing_klass = get_constant(cbase, id) # TODO: multiple return values
          if existing_klass.is_a?(Type::Class)
            klass = existing_klass
          else
            if existing_klass != Type.any
              error(ep, "the class \"#{ id }\" is #{ existing_klass.screen_name(self) }")
              id = :"#{ id }(dummy)"
            end
            existing_klass = get_constant(cbase, id) # TODO: multiple return values
            if existing_klass != Type.any
              klass = existing_klass
            else
              if type == :class
                if superclass == Type.any
                  warn(ep, "superclass is any; Object is used instead")
                  superclass = Type::Builtin[:obj]
                elsif superclass.eql?(Type.nil)
                  superclass = Type::Builtin[:obj]
                elsif superclass.is_a?(Type::Instance)
                  warn(ep, "superclass is an instance; Object is used instead")
                  superclass = Type::Builtin[:obj]
                end
              else # module
                superclass = nil
              end
              klass = new_class(cbase, id, superclass)
            end
          end
          singleton = false
        when 1 # SINGLETON_CLASS
          singleton = true
          klass = cbase
          if klass.is_a?(Type::Class)
          elsif klass.is_a?(Type::Any)
          else
            warn(ep, "A singleton class is open for #{ klass.screen_name(self) }; handled as any")
            klass = Type.any
          end
        else
          raise NotImplementedError, "unknown defineclass flag: #{ flags }"
        end
        ncref = ep.ctx.cref.extend(klass)
        recv = singleton ? Type.any : klass
        blk = env.blk_ty
        nctx = Context.new(iseq, ncref, singleton, nil)
        nep = ExecutionPoint.new(nctx, 0, nil)
        locals = [Type.nil] * iseq.locals.size
        nenv = Env.new(recv, blk, locals, [], Utils::HashWrapper.new({}))
        merge_env(nep, nenv)
        add_callsite!(nep.ctx, nil, ep, env) do |ret_ty, ep, env|
          nenv, ret_ty = localize_type(ret_ty, env, ep)
          nenv = nenv.push(ret_ty)
          merge_env(ep.next, nenv)
        end
        return
      when :send
        env, recvs, mid, aargs = setup_actual_arguments(operands, ep, env)
        recvs.each_child do |recv|
          meths = recv.get_method(mid, self)
          if meths
            meths.each do |meth|
              meth.do_send(recv, mid, aargs, ep, env, self)
            end
          else
            if recv != Type.any # XXX: should be configurable
              error(ep, "undefined method: #{ globalize_type(recv, env, ep).screen_name(self) }##{ mid }")
            end
            nenv = env.push(Type.any)
            merge_env(ep.next, nenv)
          end
        end
        return
      #when :send_is_a_and_branch
      #  send_operands, (branch_type, target,) = *operands
      #  env, recvs, mid, aargs = setup_actual_arguments(send_operands, ep, env)
      #  recvs.each_child do |recv|
      #    meths = recv.get_method(mid, self)
      #    if meths
      #      meths.each do |meth|
      #        meth.do_send(recv, mid, aargs, ep, env, self) do |ret_ty, ep, env|
      #          is_true = ret_ty.eql?(Type::Instance.new(Type::Builtin[:true]))
      #          is_false = ret_ty.eql?(Type::Instance.new(Type::Builtin[:false]))
      #          if branch_type != :nil && (is_true || is_false)
      #            if is_true == (branch_type == :if)
      #              nep = ep.jump(target)
      #              merge_env(nep, env)
      #            else
      #              nep = ep.next
      #              merge_env(nep, env)
      #            end
      #          else
      #            ep_then = ep.next
      #            ep_else = ep.jump(target)

      #            merge_env(ep_then, env)
      #            merge_env(ep_else, env)
      #          end
      #        end
      #      end
      #    else
      #      if recv != Type.any # XXX: should be configurable
      #        error(ep, "undefined method: #{ globalize_type(recv, env, ep).screen_name(self) }##{ mid }")
      #      end
      #      ep_then = ep.next
      #      ep_else = ep.jump(target)
      #      merge_env(ep_then, env)
      #      merge_env(ep_else, env)
      #    end
      #  end
      #  return
      when :invokeblock
        # XXX: need block parameter, unknown block, etc.  Use setup_actual_arguments
        opt, = operands
        _flags = opt[:flag]
        orig_argc = opt[:orig_argc]
        env, aargs = env.pop(orig_argc)
        blk = env.blk_ty
        case
        when blk.eql?(Type.nil)
          env = env.push(Type.any)
        when blk.eql?(Type.any)
          warn(ep, "block is any")
          env = env.push(Type.any)
        else # Proc
          blk_nil = Type.nil
          #
          aargs = ActualArguments.new(aargs, nil, nil, blk_nil)
          do_invoke_block(true, env.blk_ty, aargs, ep, env)
          return
        end
      when :invokesuper
        env, recv, _, aargs = setup_actual_arguments(operands, ep, env)

        recv = env.recv_ty
        mid  = ep.ctx.mid
        # XXX: need to support included module...
        meths = get_super_method(ep.ctx) # TODO: multiple return values
        if meths
          meths.each do |meth|
            meth.do_send(recv, mid, aargs, ep, env, self)
          end
          return
        else
          error(ep, "no superclass method: #{ env.recv_ty.screen_name(self) }##{ mid }")
          env = env.push(Type.any)
        end
      when :invokebuiltin
        raise NotImplementedError
      when :leave
        if env.stack.size != 1
          raise "stack inconsistency error: #{ env.stack.inspect }"
        end
        env, (ty,) = env.pop(1)
        ty = globalize_type(ty, env, ep)
        add_return_type!(ep.ctx, ty)
        return
      when :throw
        throwtype, = operands
        env, (ty,) = env.pop(1)
        case throwtype
        when 1 # return
          ty = globalize_type(ty, env, ep)
          tmp_ep = ep
          tmp_ep = tmp_ep.outer while tmp_ep.outer
          add_return_type!(tmp_ep.ctx, ty)
          return
        when 2 # break
          tmp_ep = ep.outer
          nenv = @return_envs[tmp_ep].push(ty)
          merge_env(tmp_ep.next, nenv)
          # TODO: jump to ensure?
        else
          p throwtype
          raise NotImplementedError
        end
        return
      when :once
        iseq, = operands

        recv = env.recv_ty
        blk = env.blk_ty
        nctx = Context.new(iseq, ep.ctx.cref, ep.ctx.singleton, ep.ctx.mid)
        nep = ExecutionPoint.new(nctx, 0, ep)
        raise if iseq.locals != []
        nenv = Env.new(recv, blk, [], [], nil)
        merge_env(nep, nenv)
        add_callsite!(nep.ctx, nil, ep, env) do |ret_ty, ep, env|
          nenv, ret_ty = localize_type(ret_ty, env, ep)
          nenv = nenv.push(ret_ty)
          merge_env(ep.next, nenv)
        end
        return

      when :branch # TODO: check how branchnil is used
        branchtype, target, = operands
        # branchtype: :if or :unless or :nil
        env, (ty,) = env.pop(1)
        ep_then = ep.next
        ep_else = ep.jump(target)

        # TODO: it works for only simple cases: `x = nil; x || 1`
        # It would be good to merge "dup; branchif" to make it context-sensitive-like
        falsy = ty.eql?(Type.nil)

        merge_env(ep_then, env)
        merge_env(ep_else, env) unless branchtype == :if && falsy
        return
      when :jump
        target, = operands
        merge_env(ep.jump(target), env)
        return

      when :setinstancevariable
        var, = operands
        env, (ty,) = env.pop(1)
        recv = env.recv_ty
        ty = globalize_type(ty, env, ep)
        add_ivar_write!(recv, var, ty)

      when :getinstancevariable
        var, = operands
        recv = env.recv_ty
        # TODO: deal with inheritance?
        add_ivar_read!(recv, var, ep) do |ty, ep|
          nenv, ty = localize_type(ty, env, ep)
          merge_env(ep.next, nenv.push(ty))
        end
        return

      when :setclassvariable
        var, = operands
        env, (ty,) = env.pop(1)
        cbase = ep.ctx.cref.klass
        ty = globalize_type(ty, env, ep)
        # TODO: if superclass has the variable, it should be updated
        add_cvar_write!(cbase, var, ty)

      when :getclassvariable
        var, = operands
        cbase = ep.ctx.cref.klass
        # TODO: if superclass has the variable, it should be read
        add_cvar_read!(cbase, var, ep) do |ty, ep|
          nenv, ty = localize_type(ty, env, ep)
          merge_env(ep.next, nenv.push(ty))
        end
        return

      when :setglobal
        var, = operands
        env, (ty,) = env.pop(1)
        ty = globalize_type(ty, env, ep)
        add_gvar_write!(var, ty)

      when :getglobal
        var, = operands
        add_gvar_read!(var, ep) do |ty, ep|
          ty = Type.nil if ty == Type.bot # HACK
          nenv, ty = localize_type(ty, env, ep)
          merge_env(ep.next, nenv.push(ty))
        end
        # need to return default nil of global variables
        return

      when :getlocal, :getblockparam, :getblockparamproxy
        var_idx, scope_idx, _escaped = operands
        if scope_idx == 0
          ty = env.get_local(-var_idx+2)
        else
          tmp_ep = ep
          scope_idx.times do
            tmp_ep = tmp_ep.outer
          end
          ty = @return_envs[tmp_ep].get_local(-var_idx+2)
        end
        env = env.push(ty)
      when :setlocal, :setblockparam
        var_idx, scope_idx, _escaped = operands
        env, (ty,) = env.pop(1)
        if scope_idx == 0
          env = env.local_update(-var_idx+2, ty)
        else
          tmp_ep = ep
          scope_idx.times do
            tmp_ep = tmp_ep.outer
          end
          merge_return_env(tmp_ep) do |env|
            env.merge(env.local_update(-var_idx+2, ty))
          end
        end
      when :getconstant
        name, = operands
        env, (cbase, _allow_nil,) = env.pop(2)
        if cbase.eql?(Type.nil)
          ty = search_constant(ep.ctx.cref, name)
          env, ty = localize_type(ty, env, ep)
          env = env.push(ty)
        elsif cbase.eql?(Type.any)
          env = env.push(Type.any) # XXX: warning needed?
        else
          ty = get_constant(cbase, name)
          env, ty = localize_type(ty, env, ep)
          env = env.push(ty)
        end
      when :setconstant
        name, = operands
        env, (ty, cbase) = env.pop(2)
        old_ty = get_constant(cbase, name)
        if old_ty != Type.any # XXX???
          warn(ep, "already initialized constant #{ Type::Instance.new(cbase).screen_name(self) }::#{ name }")
        end
        add_constant(cbase, name, globalize_type(ty, env, ep))

      when :getspecial
        key, type = operands
        if type == 0
          raise NotImplementedError
          case key
          when 0 # VM_SVAR_LASTLINE
            env = env.push(Type.any) # or String | NilClass only?
          when 1 # VM_SVAR_BACKREF ($~)
            merge_env(ep.next, env.push(Type::Instance.new(Type::Builtin[:matchdata])))
            merge_env(ep.next, env.push(Type.nil))
            return
          else # flip-flop
            env = env.push(Type.bool)
          end
        else
          # NTH_REF ($1, $2, ...) / BACK_REF ($&, $+, ...)
          merge_env(ep.next, env.push(Type::Instance.new(Type::Builtin[:str])))
          merge_env(ep.next, env.push(Type.nil))
          return
        end
      when :setspecial
        # flip-flop
        raise NotImplementedError, "setspecial"

      when :dup
        env, (ty,) = env.pop(1)
        env = env.push(ty).push(ty)
      when :duphash
        raw_hash, = operands
        ty = Type.guess_literal_type(raw_hash)
        env, ty = localize_type(globalize_type(ty, env, ep), env, ep)
        env = env.push(ty)
      when :dupn
        n, = operands
        _, tys = env.pop(n)
        tys.each {|ty| env = env.push(ty) }
      when :pop
        env, = env.pop(1)
      when :swap
        env, (a, b) = env.pop(2)
        env = env.push(a).push(b)
      when :reverse
        raise NotImplementedError, "reverse"
      when :defined
        env, = env.pop(1)
        sym_ty = Type::Symbol.new(nil, Type::Instance.new(Type::Builtin[:sym]))
        env = env.push(Type.optional(sym_ty))
      when :checkmatch
        flag, = operands
        array = flag & 4 != 0
        case flag & 3
        when 1
          raise NotImplementedError
        when 2 # VM_CHECKMATCH_TYPE_CASE
          raise NotImplementedError if array
          env, = env.pop(2)
          env = env.push(Type.bool)
        when 3
          raise NotImplementedError
        else
          raise "unknown checkmatch flag"
        end
      when :checkkeyword
        env = env.push(Type.bool)
      when :adjuststack
        n, = operands
        env, _ = env.pop(n)
      when :nop
      when :setn
        idx, = operands
        env, (ty,) = env.pop(1)
        env = env.setn(idx, ty).push(ty)
      when :topn
        idx, = operands
        env = env.topn(idx)

      when :splatarray
        env, (ty,) = env.pop(1)
        # XXX: vm_splat_array
        env = env.push(ty)
      when :expandarray
        num, flag = operands
        env, (ary,) = env.pop(1)
        splat = flag & 1 == 1
        from_head = flag & 2 == 0
        case ary
        when Type::LocalArray
          elems = get_container_elem_types(env, ep, ary.id)
          elems ||= Type::Array::Elements.new([], Type.any) # XXX
          do_expand_array(ep, env, elems, num, splat, from_head)
          return
        when Type::Any
          splat = flag & 1 == 1
          num += 1 if splat
          num.times do
            env = env.push(Type.any)
          end
        else
          # TODO: call to_ary (or to_a?)
          elems = Type::Array::Elements.new([ary], Type.bot)
          do_expand_array(ep, env, elems, num, splat, from_head)
          return
        end
      when :concatarray
        env, (ary1, ary2) = env.pop(2)
        if ary1.is_a?(Type::LocalArray)
          elems1 = get_container_elem_types(env, ep, ary1.id)
          if ary2.is_a?(Type::LocalArray)
            elems2 = get_container_elem_types(env, ep, ary2.id)
            elems = Type::Array::Elements.new([], elems1.squash.union(elems2.squash))
            env = env.update_container_elem_types(ary1.id, elems)
            env = env.push(ary1)
          else
            elems = Type::Array::Elements.new([], Type.any)
            env = env.update_container_elem_types(ary1.id, elems)
            env = env.push(ary1)
          end
        else
          ty = Type::Array.new(Type::Array::Elements.new([], Type.any), Type::Instance.new(Type::Builtin[:ary]))
          env, ty = localize_type(ty, env, ep)
          env = env.push(ty)
        end

      when :checktype
        type, = operands
        raise NotImplementedError if type != 5 # T_STRING
        # XXX: is_a?
        env, (val,) = env.pop(1)
        res = globalize_type(val, env, ep) == Type::Instance.new(Type::Builtin[:str])
        if res
          ty = Type::Instance.new(Type::Builtin[:true])
        else
          ty = Type::Instance.new(Type::Builtin[:false])
        end
        env = env.push(ty)
      else
        raise "Unknown insn: #{ insn }"
      end

      add_edge(ep, ep)
      merge_env(ep.next, env)
    end

    private def do_expand_array(ep, env, elems, num, splat, from_head)
      if from_head
        lead_tys, rest_ary_ty = elems.take_first(num)
        if splat
          env, local_ary_ty = localize_type(rest_ary_ty, env, ep)
          env = env.push(local_ary_ty)
        end
        lead_tys.reverse_each do |ty|
          env = env.push(ty)
        end
      else
        rest_ary_ty, following_tys = elems.take_last(num)
        following_tys.each do |ty|
          env = env.push(ty)
        end
        if splat
          env, local_ary_ty = localize_type(rest_ary_ty, env, ep)
          env = env.push(local_ary_ty)
        end
      end
      merge_env(ep.next, env)
    end

    private def setup_actual_arguments(operands, ep, env)
      opt, blk_iseq = operands
      flags = opt[:flag]
      mid = opt[:mid]
      kw_arg = opt[:kw_arg]
      argc = opt[:orig_argc]
      argc += 1 # receiver
      argc += kw_arg.size if kw_arg

      flag_args_splat    = flags[ 0] != 0
      flag_args_blockarg = flags[ 1] != 0
      _flag_args_fcall   = flags[ 2] != 0
      _flag_args_vcall   = flags[ 3] != 0
      _flag_args_simple  = flags[ 4] != 0 # unused in TP
      _flag_blockiseq    = flags[ 5] != 0 # unused in VM :-)
      flag_args_kwarg    = flags[ 6] != 0
      flag_args_kw_splat = flags[ 7] != 0
      _flag_tailcall     = flags[ 8] != 0
      _flag_super        = flags[ 9] != 0
      _flag_zsuper       = flags[10] != 0

      if flag_args_blockarg
        env, (recv, *aargs, blk_ty) = env.pop(argc + 1)
        raise "both block arg and actual block given" if blk_iseq
      else
        env, (recv, *aargs) = env.pop(argc)
        if blk_iseq
          # check
          blk_ty = Type::ISeqProc.new(blk_iseq, ep, env, Type::Instance.new(Type::Builtin[:proc]))
        else
          blk_ty = Type.nil
        end
      end

      case blk_ty
      when Type.nil
      when Type.any
      when Type::ISeqProc
      else
        error(ep, "wrong argument type #{ blk_ty.screen_name(self) } (expected Proc)")
        blk_ty = Type.any
      end

      if flag_args_splat
        # assert !flag_args_kwarg
        rest_ty = aargs.last
        aargs = aargs[0..-2]
        if flag_args_kw_splat
          ty = globalize_type(rest_ty, env, ep)
          if ty.is_a?(Type::Array)
            _, (ty,) = ty.elems.take_last(1)
            case ty
            when Type::Hash
              kw_ty = ty
            when Type::Union
              kw_ty = Type::Hash.new(ty.hash_elems, Type::Instance.new(Type::Builtin[:hash]))
            else
              warn(ep, "non hash is passed to **kwarg?") unless ty == Type.any
              kw_ty = nil
            end
          else
            raise NotImplementedError
          end
          # XXX: should we remove kw_ty from rest_ty?
        end
        aargs = ActualArguments.new(aargs, rest_ty, kw_ty, blk_ty)
      elsif flag_args_kw_splat
        last = aargs.last
        ty = globalize_type(last, env, ep)
        case ty
        when Type::Hash
          aargs = aargs[0..-2]
          kw_ty = ty
        when Type::Union
          kw_ty = Type::Hash.new(ty.hash_elems, Type::Instance.new(Type::Builtin[:hash]))
        else
          warn(ep, "non hash is passed to **kwarg?") unless ty == Type.any
          kw_ty = nil
        end
        aargs = ActualArguments.new(aargs, nil, kw_ty, blk_ty)
      elsif flag_args_kwarg
        kw_vals = aargs.pop(kw_arg.size)

        kw_ty = Type.gen_hash do |h|
          kw_arg.zip(kw_vals) do |key, v_ty|
            k_ty = Type::Symbol.new(key, Type::Instance.new(Type::Builtin[:sym]))
            h[k_ty] = v_ty
          end
        end

        # kw_ty is Type::Hash, but we don't have to localize it, maybe?

        aargs = ActualArguments.new(aargs, nil, kw_ty, blk_ty)
      else
        aargs = ActualArguments.new(aargs, nil, nil, blk_ty)
      end

      return env, recv, mid, aargs
    end

    def do_invoke_block(given_block, blk, aargs, ep, env, &ctn)
      if ctn
        do_invoke_block_core(given_block, blk, aargs, ep, env, &ctn)
      else
        do_invoke_block_core(given_block, blk, aargs, ep, env) do |ret_ty, ep, env|
          nenv, ret_ty, = localize_type(ret_ty, env, ep)
          nenv = nenv.push(ret_ty)
          merge_env(ep.next, nenv)
        end
      end
    end

    private def do_invoke_block_core(given_block, blk, aargs, ep, env, &ctn)
      blk.each_child do |blk|
        unless blk.is_a?(Type::ISeqProc)
          warn(ep, "non-iseq-proc is passed as a block")
          next
        end
        blk_iseq = blk.iseq
        blk_ep = blk.ep
        blk_env = blk.env
        arg_blk = aargs.blk_ty
        aargs_ = aargs.lead_tys.map {|aarg| globalize_type(aarg, env, ep) }
        argc = blk_iseq.fargs_format[:lead_num] || 0
        if argc != aargs_.size
          warn(ep, "complex parameter passing of block is not implemented")
          aargs_.pop while argc < aargs_.size
          aargs_ << Type.any while argc > aargs_.size
        end
        locals = [Type.nil] * blk_iseq.locals.size
        locals[blk_iseq.fargs_format[:block_start]] = arg_blk if blk_iseq.fargs_format[:block_start]
        recv = blk_env.recv_ty
        env_blk = blk_env.blk_ty
        nfargs = FormalArguments.new(aargs_, [], nil, [], nil, nil, env_blk) # XXX: aargs_ -> fargs
        nctx = Context.new(blk_iseq, blk_ep.ctx.cref, nil, nil)
        nep = ExecutionPoint.new(nctx, 0, blk_ep)
        nenv = Env.new(recv, env_blk, locals, [], nil)
        alloc_site = AllocationSite.new(nep)
        aargs_.each_with_index do |ty, i|
          alloc_site2 = alloc_site.add_id(i)
          nenv, ty = localize_type(ty, nenv, nep, alloc_site2) # Use Scratch#localize_type?
          nenv = nenv.local_update(i, ty)
        end

        merge_env(nep, nenv)

        # caution: given_block flag is not complete
        #
        # def foo
        #   bar do |&blk|
        #     yield
        #     blk.call
        #   end
        # end
        #
        # yield and blk.call call different blocks.
        # So, a context can have two blocks.
        # given_block is calculated by comparing "context's block (yield target)" and "blk", but it is not a correct result

        add_yield!(ep.ctx, nfargs, nep.ctx) if given_block
        add_callsite!(nep.ctx, nil, ep, env, &ctn)
      end
    end
  end
end
