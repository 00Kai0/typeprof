class Object
  def foo
    self
  end
end

def bar(ary)
  ary.foo
end

bar([])

__END__
# Classes
class Object
  def foo : -> Array[bot]
  def bar : (Array[bot]) -> Array[bot]
end
