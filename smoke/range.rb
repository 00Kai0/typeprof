# dummy implementation

def foo(x, y)
  (x..y)
end

foo(1, 2)

__END__
# Classes
class Object
  foo : (Integer, Integer) -> Range
end
