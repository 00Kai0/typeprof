module TypeProfiler
  class ISeq
    include Utils::StructuralEquality

    def self.compile(file)
      opt = RubyVM::InstructionSequence.compile_option
      opt[:inline_const_cache] = false
      opt[:peephole_optimization] = false
      opt[:specialized_instruction] = false
      opt[:operands_unification] = false
      opt[:coverage_enabled] = false
      new(RubyVM::InstructionSequence.compile_file(file, **opt).to_a)
    end

    def self.compile_str(str)
      opt = RubyVM::InstructionSequence.compile_option
      opt[:inline_const_cache] = false
      opt[:peephole_optimization] = false
      opt[:specialized_instruction] = false
      opt[:operands_unification] = false
      opt[:coverage_enabled] = false
      new(RubyVM::InstructionSequence.compile(str, **opt).to_a)
    end

    FRESH_ID = [0]

    def initialize(iseq)
      @id = FRESH_ID[0]
      FRESH_ID[0] += 1

      _magic, _major_version, _minor_version, _format_type, _misc,
        @name, @path, @absolute_path, @start_lineno, @type,
        @locals, @fargs_format, catch_table, insns = *iseq

      @insns = []
      @linenos = []

      labels = setup_iseq(insns)

      @catch_table = []
      catch_table.map do |type, iseq, first, last, cont, stack_depth|
        iseq = iseq ? ISeq.new(iseq) : nil
        entry = [type, iseq, labels[cont], stack_depth]
        labels[first].upto(labels[last]) do |i|
          @catch_table[i] ||= []
          @catch_table[i] << entry
        end
      end

      merge_branches
    end

    def <=>(other)
      @id <=> other.id
    end

    def setup_iseq(insns)
      i = 0
      labels = {}
      insns.each do |e|
        if e.is_a?(Symbol) && e.to_s.start_with?("label")
          labels[e] = i
        elsif e.is_a?(Array)
          i += 1
        end
      end

      lineno = 0
      insns.each do |e|
        case e
        when Integer # lineno
          lineno = e
        when Symbol # label or trace
          nil
        when Array
          insn, *operands = e
          operands = INSN_TABLE[insn].zip(operands).map do |type, operand|
            case type
            when "ISEQ"
              operand && ISeq.new(operand)
            when "lindex_t", "rb_num_t", "VALUE", "ID", "GENTRY", "CALL_DATA"
              operand
            when "OFFSET"
              labels[operand] || raise("unknown label: #{ operand }")
            when "IVC", "ISE"
              raise unless operand.is_a?(Integer)
              :_cache_operand
            else
              raise "unknown operand type: #{ type }"
            end
          end

          @insns << [insn, operands]
          @linenos << lineno
        else
          raise "unknown iseq entry: #{ e }"
        end
      end

      @fargs_format[:opt] = @fargs_format[:opt].map {|l| labels[l] } if @fargs_format[:opt]

      labels
    end

    def merge_branches
      @insns.size.times do |i|
        insn, operands = @insns[i]
        case insn
        when :branchif
          @insns[i] = [:branch, [:if] + operands]
        when :branchunless
          @insns[i] = [:branch, [:unless] + operands]
        when :branchnil
          @insns[i] = [:branch, [:nil] + operands]
        end
      end
    end

    def determine_stack
    end

    def make_special_send
      #(@insns.size - 1).times do |i|
      #  insn, *operands = @insns[i]
      #  if insn == :send && operands[0][:mid] == :is_a?
      #    insn2, *operands2 = @insns[i + 1]
      #    if insn2 == :branch
      #      @insns[i] = [:nop]
      #      @insns[i + 1] = [:send_is_a_and_branch, operands, operands2]
      #    end
      #  end
      #end
    end

    def source_location(pc)
      "#{ @path }:#{ @linenos[pc] }"
    end

    attr_reader :name, :path, :abolute_path, :start_lineno, :type, :locals, :fargs_format, :catch_table, :insns, :linenos
    attr_reader :id

    def pretty_print(q)
      q.text "ISeq["
      q.group do
        q.nest(1) do
          q.breakable ""
          q.text "@type=          #{ @type }"
          q.breakable ", "
          q.text "@name=          #{ @name }"
          q.breakable ", "
          q.text "@path=          #{ @path }"
          q.breakable ", "
          q.text "@absolute_path= #{ @absolute_path }"
          q.breakable ", "
          q.text "@start_lineno=  #{ @start_lineno }"
          q.breakable ", "
          q.text "@fargs_format=  #{ @fargs_format.inspect }"
          q.breakable ", "
          q.text "@insns="
          q.group(2) do
            @insns.each_with_index do |(insn, *operands), i|
              q.breakable
              q.group(2, "#{ i }: #{ insn.to_s }", "") do
                q.pp operands
              end
            end
          end
        end
        q.breakable
      end
      q.text "]"
    end
  end
end
