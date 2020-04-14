def bar
  baz do
    yield
  end
end

def baz
  yield
end

def foo
  a = 42
  bar do
    a = "str"
  end
  a
end

foo

__END__
# Classes
class Object
  def bar : () -> String
  def baz : (&Proc[(&Proc[() -> String]) -> String]) -> String
  def foo : () -> (Integer | String)
end
