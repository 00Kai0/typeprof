class A
  def self.foo(x); "str"; end
end
class B < A
end
A.foo(1)
B.foo(Integer)

__END__
# Classes
class A
  def self.foo : (Integer | Integer.class) -> String
end

class B < A
end
