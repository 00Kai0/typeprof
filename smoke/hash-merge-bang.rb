def foo
  h = { a: 42 }
  h0 = h.merge!({ b: "str" })
  return h0, h
end

__END__
# Classes
class Object
  def foo : -> ([{:a=>Integer | String, :b=>Integer | String}, {:a=>Integer, :b=>String}])
end
