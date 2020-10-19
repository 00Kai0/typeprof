class A
end

class B
end

Base = rand < 0.5 ? A : B

class C < Base
end

__END__
# Errors
smoke/multiple-superclass.rb:9: [warning] superclass is not a class; Object is used instead

# Classes
class A
end

class B
end

class C
end
