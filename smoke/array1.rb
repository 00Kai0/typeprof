def foo(a)
  a[0]
end
def bar(n); end
def baz(n); end
def qux(n); end
def quux(n); end

a = [42, "str"]
foo(a)
bar(a[0])
n = 1
baz(a[n])
qux(a[2])
n = 0+0
quux(a[n])

__END__
# Classes
class Object
  def foo : ([Integer, String]) -> Integer
  def bar : (Integer) -> NilClass
  def baz : (String) -> NilClass
  def qux : (NilClass) -> NilClass
  def quux : (Integer | String) -> NilClass
end
