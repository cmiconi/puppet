require File.dirname(__FILE__) + '/../../spec_helper'
require 'puppet/defaults'
require 'puppet/indirector'

describe Puppet::Indirector, " when available to a model" do
    before do
        @thingie = Class.new do
            extend Puppet::Indirector
        end
    end

    it "should provide a way for the model to register an indirection under a name" do
        @thingie.should respond_to(:indirects)
    end
end

describe Puppet::Indirector, "when registering an indirection" do
    before do
        @thingie = Class.new do
            extend Puppet::Indirector
        end
    end

    it "should require a name when registering a model" do
        Proc.new {@thingie.send(:indirects) }.should raise_error(ArgumentError)
    end

    it "should create an indirection instance to manage each indirecting model" do
        @indirection = @thingie.indirects(:test)
        @indirection.should be_instance_of(Puppet::Indirector::Indirection)
    end
    
    it "should not allow a model to register under multiple names" do
        # Keep track of the indirection instance so we can delete it on cleanup
        @indirection = @thingie.indirects :first
        Proc.new { @thingie.indirects :second }.should raise_error(ArgumentError)
    end

    it "should set up instance loading for the indirection" do
        Puppet::Indirector.expects(:instance_load).with(:test, "puppet/indirector/test")
        @indirection = @thingie.indirects(:test)
    end

    after do
        @indirection.delete if @indirection
    end

# TODO:  node lookup retries/searching
end

describe Puppet::Indirector, " when redirecting model" do
  before do
    @thingie = Class.new do
      extend Puppet::Indirector
    end
    @mock_terminus = mock('Terminus')
    @indirection = @thingie.send(:indirects, :test)
    @thingie.expects(:indirection).returns(@mock_terminus)
  end
  
  it "should give model the ability to lookup a model instance by letting the indirection perform the lookup" do
    @mock_terminus.expects(:find)
    @thingie.find
  end

  it "should give model the ability to remove model instances from a terminus by letting the indirection remove the instance" do
    @mock_terminus.expects(:destroy)
    @thingie.destroy  
  end
  
  it "should give model the ability to search for model instances by letting the indirection find the matching instances" do
    @mock_terminus.expects(:search)
    @thingie.search    
  end
  
  it "should give model the ability to store a model instance by letting the indirection store the instance" do
    thing = @thingie.new
    @mock_terminus.expects(:save).with(thing)
    thing.save        
  end

  after do
      @indirection.delete
  end
end

describe Puppet::Indirector, " when retrieving terminus classes" do
    it "should allow terminus classes to register themselves"

    it "should provide a method to retrieve a terminus class by name and indirection" do
        Puppet::Indirector.expects(:loaded_instance).with(:indirection, :terminus)
        Puppet::Indirector.terminus(:indirection, :terminus)
    end
end


# describe Puppet::Indirector::Terminus do
#   it "should register itself"  # ???
#   
#   it "should allow for finding an object from a collection"
#   it "should allow for finding matching objects from a collection"
#   it "should allow for destroying an object in a collection"
#   it "should allow an object to be saved to a collection"
#   it "should allow an object class to pre-process its arguments"
#   it "should allow an object class to be in a read-only collection"
#   
#   it "should look up the appropriate decorator for the class"
#   it "should call "
# end
