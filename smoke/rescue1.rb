def foo(x)
  42
end

def bar
  x = 1
  x = "str"
  x = :sym
rescue
  foo(x)
end

bar

__END__
# Classes
class Object
  def foo : (:sym | Integer | NilClass | String) -> Integer
  def bar : () -> (:sym | Integer)
end
