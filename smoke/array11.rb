def array(obj)
    Array(obj)
end

array({1=>1})
array([1]+[2])
array("foo")

__END__
# Classes
class Object
  def array : (Array[Integer] | Hash[Integer, Integer] | String) -> (Array[Hash[Integer, Integer] | Integer | String])
end
