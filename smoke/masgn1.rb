def foo
  ary = [1, "str", :sym, nil]
  a, *rest, z = *ary
  [a, rest, z]
end

foo

__END__
# Classes
class Object
  foo : () -> [Integer, [String, Symbol], NilClass]
end
