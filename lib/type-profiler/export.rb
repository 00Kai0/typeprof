module TypeProfiler
  module Reporters
    module_function

    def generate_analysis_trace(state, visited, backward_edge)
      return nil if visited[state]
      visited[state] = true
      prev_states = backward_edges[state]
      if prev_states
        prev_states.each_key do |pstate|
          trace = generate_analysis_trace(pstate, visited, backward_edge)
          return [state] + trace if trace
        end
        nil
      else
        []
      end
    end

    def filter_backtrace(trace)
      ntrace = [trace.first]
      trace.each_cons(2) do |ep1, ep2|
        ntrace << ep2 if ep1.ctx != ep2.ctx
      end
      ntrace
    end

    def show_error(errors, backward_edge)
      return if errors.empty?

      puts "# Errors"
      errors.each do |ep, msg|
        if ENV["TYPE_PROFILER_DETAIL"]
          backtrace = filter_backtrace(generate_analysis_trace(ep, {}, backward_edge))
        else
          backtrace = [ep]
        end
        loc, *backtrace = backtrace.map do |ep|
          ep.source_location
        end
        puts "#{ loc }: #{ msg }"
        backtrace.each do |loc|
          puts "        from #{ loc }"
        end
      end
      puts
    end

    def show_reveal_types(scratch, reveal_types)
      return if reveal_types.empty?

      puts "# Revealed types"
      reveal_types.each do |source_location, ty|
        puts "#  #{ source_location } #=> #{ ty.screen_name(scratch) }"
      end
      puts
    end

    def show_gvars(scratch, gvar_write)
      # A signature for global variables is not supported in RBS
      return if gvar_write.empty?

      puts "# Global variables"
      gvar_write.each do |gvar_name, ty|
        puts "#  #{ gvar_name } : #{ ty.screen_name(scratch) }"
      end
      puts
    end
  end

  class RubySignatureExporter
    def initialize(
      scratch,
      class_defs, iseq_method_to_ctxs, sig_fargs, sig_ret, yields
    )
      @scratch = scratch
      @class_defs = class_defs
      @iseq_method_to_ctxs = iseq_method_to_ctxs
      @sig_fargs = sig_fargs
      @sig_ret = sig_ret
      @yields = yields
    end

    def show_signature(farg_tys, blk_ctxs, ret_ty)
      s = "(#{ farg_tys.join(", ") }) "
      s << "{ #{ show_block_signature(blk_ctxs) } } " if blk_ctxs
      s << "-> "
      s << (ret_ty.include?("|") ? "(#{ ret_ty })" : ret_ty)
    end

    def show_block_signature(blk_ctxs)
      blk_tys = {}
      all_farg_tys = all_ret_tys = nil
      blk_ctxs.each do |blk_ctx, farg_tys|
        if all_farg_tys
          all_farg_tys = all_farg_tys.merge(farg_tys)
        else
          all_farg_tys = farg_tys
        end

        if all_ret_tys
          all_ret_tys = all_ret_tys.union(@sig_ret[blk_ctx])
        else
          all_ret_tys = @sig_ret[blk_ctx]
        end
      end
      all_farg_tys = all_farg_tys.screen_name(@scratch)
      all_ret_tys = all_ret_tys.screen_name(@scratch)
      # XXX: should support @yields[blk_ctx] (block's block)
      show_signature(all_farg_tys, nil, all_ret_tys)
    end

    def show(stat_eps)
      puts "# Classes" # and Modules

      stat_classes = {}
      stat_methods = {}
      first = true
      @class_defs.each_value do |class_def|
        included_mods = class_def.modules[false].filter_map do |visible, mod_def|
          mod_def.name if visible
        end

        ivars = class_def.ivars.write.map do |(singleton, var), ty|
          var = "self.#{ var }" if singleton
          [var, ty.screen_name(@scratch)]
        end

        cvars = class_def.cvars.write.map do |var, ty|
          [var, ty.screen_name(@scratch)]
        end

        methods = {}
        class_def.methods.each do |(singleton, mid), mdefs|
          mdefs.each do |mdef|
            ctxs = @iseq_method_to_ctxs[mdef]
            next unless ctxs

            ctxs.each do |ctx|
              next if mid != ctx.mid

              method_name = ctx.mid
              method_name = "self.#{ method_name }" if singleton

              fargs = @sig_fargs[ctx].screen_name(@scratch)
              ret_tys = @sig_ret[ctx].screen_name(@scratch)

              methods[method_name] ||= []
              methods[method_name] << show_signature(fargs, @yields[ctx], ret_tys)

              #stat_classes[recv] = true
              #stat_methods[[recv, method_name]] = true
            end
          end
        end

        next if included_mods.empty? && ivars.empty? && cvars.empty? && methods.empty?

        puts unless first
        first = false

        puts "#{ class_def.kind } #{ class_def.name }"
        included_mods.sort.each do |ty|
          puts "  include #{ ty }"
        end
        ivars.each do |var, ty|
          puts "  #{ var } : #{ ty }"
        end
        cvars.each do |var, ty|
          puts "  #{ var } : #{ ty }"
        end
        methods.each do |method_name, sigs|
          sigs = sigs.sort.join("\n" + " " * (method_name.size + 3) + "| ")
          puts "  def #{ method_name } : #{ sigs }"
        end
        puts "end"
      end

      if ENV["TP_STAT"]
        puts "statistics:"
        puts "  %d execution points" % stat_eps.size
        puts "  %d classes" % stat_classes.size
        puts "  %d methods (in total)" % stat_methods.size
      end
      if ENV["TP_COVERAGE"]
        coverage = {}
        stat_eps.each do |ep|
          path = ep.ctx.iseq.path
          lineno = ep.ctx.iseq.linenos[ep.pc] - 1
          (coverage[path] ||= [])[lineno] ||= 0
          (coverage[path] ||= [])[lineno] += 1
        end
        File.binwrite("coverage.dump", Marshal.dump(coverage))
      end
    end
  end
end
