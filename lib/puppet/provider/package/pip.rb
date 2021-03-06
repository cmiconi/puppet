# Puppet package provider for Python's `pip` package management frontend.
# <http://pip.pypa.io/>

require 'puppet/util/package/version/pip'
require 'puppet/util/package/version/range'
require 'puppet/provider/package_targetable'
require 'puppet/util/http_proxy'

Puppet::Type.type(:package).provide :pip, :parent => ::Puppet::Provider::Package::Targetable do

  desc "Python packages via `pip`.

  This provider supports the `install_options` attribute, which allows command-line flags to be passed to pip.
  These options should be specified as an array where each element is either a string or a hash."

  has_feature :installable, :uninstallable, :upgradeable, :versionable, :version_ranges, :install_options, :targetable

  PIP_VERSION       = Puppet::Util::Package::Version::Pip
  PIP_VERSION_RANGE = Puppet::Util::Package::Version::Range

  # Override the specificity method to return 1 if pip is not set as default provider
  def self.specificity
    match = default_match
    length = match ? match.length : 0

    return 1 if length == 0

    super
  end

  # Define the default provider package command name when the provider is targetable.
  # Required by Puppet::Provider::Package::Targetable::resource_or_provider_command
  def self.provider_command
    # Ensure pip can upgrade pip, which usually puts pip into a new path /usr/local/bin/pip (compared to /usr/bin/pip)
    self.cmd.map { |c| which(c) }.find { |c| c != nil }
  end

  def self.cmd
    if Puppet::Util::Platform.windows?
      ["pip.exe"]
    else
      ["pip", "pip-python", "pip2", "pip-2"]
    end
  end

  def self.pip_version(command)
    version = nil
    execpipe [quote(command), '--version'] do |process|
      process.collect do |line|
        md = line.strip.match(/^pip (\d+\.\d+\.?\d*).*$/)
        if md
          version = md[1]
          break
        end
      end
    end

    raise Puppet::Error, _("Cannot resolve pip version") unless version

    version
  end

  # Return an array of structured information about every installed package
  # that's managed by `pip` or an empty array if `pip` is not available.
  def self.instances(target_command = nil)
    if target_command
      command = target_command
      self.validate_command(command)
    else
      command = provider_command
    end

    packages = []
    return packages unless command

    command_options = ['freeze']
    command_version = self.pip_version(command)
    if Puppet::Util::Package.versioncmp(command_version, '8.1.0') >= 0
      command_options << '--all'
    end

    execpipe [command, command_options] do |process|
      process.collect do |line|
        pkg = parse(line)
        next unless pkg
        pkg[:command] = command
        packages << new(pkg)
      end
    end

    # Pip can also upgrade pip, but it's not listed in freeze so need to special case it
    # Pip list would also show pip installed version, but "pip list" doesn't exist for older versions of pip (E.G v1.0)
    # Not needed when "pip freeze --all" is available.
    if Puppet::Util::Package.versioncmp(command_version, '8.1.0') == -1
      packages << new({:ensure => command_version, :name => File.basename(command), :provider => name, :command => command})
    end

    packages
  end

  # Parse lines of output from `pip freeze`, which are structured as:
  # _package_==_version_ or _package_===_version_
  def self.parse(line)
    if line.chomp =~ /^([^=]+)===?([^=]+)$/
      {:ensure => $2, :name => $1, :provider => name}
    end
  end

  # Return structured information about a particular package or `nil`
  # if the package is not installed or `pip` itself is not available.
  def query
    command = resource_or_provider_command
    self.class.validate_command(command)

    self.class.instances(command).each do |pkg|
      return pkg.properties if @resource[:name].casecmp(pkg.name).zero?
    end
    return nil
  end

  # Return latest version available for current package
  def latest
    command = resource_or_provider_command
    self.class.validate_command(command)

    command_version = self.class.pip_version(command)
    if Puppet::Util::Package.versioncmp(command_version, '1.5.4') == -1
      latest_with_old_pip
    else
      latest_with_new_pip
    end
  end

  # Less resource-intensive approach for pip version 1.5.4 and newer.
  def latest_with_new_pip
    available_versions_with_new_pip.last
  end

  # More resource-intensive approach for pip version 1.5.3 and older.
  def latest_with_old_pip
    command = resource_or_provider_command
    self.class.validate_command(command)

    Dir.mktmpdir("puppet_pip") do |dir|
      command_and_options = [command, 'install', "#{@resource[:name]}", '-d', "#{dir}", '-v']
      command_and_options << install_options if @resource[:install_options]
      execpipe command_and_options do |process|
        process.collect do |line|
          # PIP OUTPUT: Using version 0.10.1 (newest of versions: 1.2.3, 4.5.6)
          if line =~ /Using version (.+?) \(newest of versions/
            return $1
          end
        end
        return nil
      end
    end
  end

  # Use pip CLI to look up versions from PyPI repositories,
  # honoring local pip config such as custom repositories.
  def available_versions
    command = resource_or_provider_command
    self.class.validate_command(command)

    command_version = self.class.pip_version(command)
    if Puppet::Util::Package.versioncmp(command_version, '1.5.4') == -1
      available_versions_with_old_pip
    else
      available_versions_with_new_pip
    end
  end

  def available_versions_with_new_pip
    command = resource_or_provider_command
    self.class.validate_command(command)

    command_and_options = [command, 'install', "#{@resource[:name]}==versionplease"]
    command_and_options << install_options if @resource[:install_options]
    execpipe command_and_options do |process|
      process.collect do |line|
        # PIP OUTPUT: Could not find a version that satisfies the requirement example==versionplease (from versions: 1.2.3, 4.5.6)
        if line =~ /from versions: (.+)\)/
          versionList = $1.split(', ').sort do |x,y|
            Puppet::Util::Package.versioncmp(x, y)
          end
          return versionList
        end
      end
    end
    []
  end

  def available_versions_with_old_pip
    command = resource_or_provider_command
    self.class.validate_command(command)

    Dir.mktmpdir("puppet_pip") do |dir|
      command_and_options = [command, 'install', "#{@resource[:name]}", '-d', "#{dir}", '-v']
      command_and_options << install_options if @resource[:install_options]
      execpipe command_and_options do |process|
        process.collect do |line|
          # PIP OUTPUT: Using version 0.10.1 (newest of versions: 1.2.3, 4.5.6)
          if line =~ /Using version .+? \(newest of versions: (.+?)\)/
            versionList = $1.split(', ').sort do |x,y|
              Puppet::Util::Package.versioncmp(x, y)
            end
            return versionList
          end
        end
      end
      return []
    end
  end

  # Finds the most suitable version available in a given range
  def best_version(should_range)
    included_available_versions = []
    available_versions.each do |version|
      version = PIP_VERSION.parse(version)
      included_available_versions.push(version) if should_range.include?(version)
    end

    included_available_versions.sort!
    return included_available_versions.last unless included_available_versions.empty?

    Puppet.debug("No available version for package #{@resource[:name]} is included in range #{should_range}")
    should_range
  end

  # Install a package.  The ensure parameter may specify installed,
  # latest, a version number, or, in conjunction with the source
  # parameter, an SCM revision.  In that case, the source parameter
  # gives the fully-qualified URL to the repository.
  def install
    command = resource_or_provider_command
    self.class.validate_command(command)

    should = @resource[:ensure]
    command_options = %w{install -q}
    command_options +=  install_options if @resource[:install_options]
    if @resource[:source]
      if String === should
        command_options << "#{@resource[:source]}@#{should}#egg=#{@resource[:name]}"
      else
        command_options << "#{@resource[:source]}#egg=#{@resource[:name]}"
      end
    else
      case should
      when :latest
        command_options << "--upgrade" << @resource[:name]
      when String
        begin
          should_range = PIP_VERSION_RANGE.parse(should, PIP_VERSION)
          should = best_version(should_range)

          unless should == should_range
            command_options << "#{@resource[:name]}==#{should}"
          else
            # when no suitable version for the given range was found, let pip handle
            if should.is_a?(PIP_VERSION_RANGE::MinMax)
              command_options << "#{@resource[:name]} #{should.split.join(',')}"
            else
              command_options << "#{@resource[:name]} #{should}"
            end
          end
        rescue PIP_VERSION_RANGE::ValidationFailure, PIP_VERSION::ValidationFailure
          Puppet.debug("Cannot parse #{should} as a pip version range, falling through.")
          command_options << "#{@resource[:name]}==#{should}"
        end
      else
        command_options << @resource[:name]
      end
    end

    execute([command, command_options])
  end

  # Uninstall a package. Uninstall won't work reliably on Debian/Ubuntu unless this issue gets fixed.
  # http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=562544
  def uninstall
    command = resource_or_provider_command
    self.class.validate_command(command)

    command_options = ["uninstall", "-y", "-q", @resource[:name]]

    execute([command, command_options])
  end

  def update
    install
  end

  def install_options
    join_options(@resource[:install_options])
  end

  def insync?(is)
    return false unless is && is != :absent
    begin
      should = @resource[:ensure]
      should_range = PIP_VERSION_RANGE.parse(should, PIP_VERSION)
    rescue PIP_VERSION_RANGE::ValidationFailure, PIP_VERSION::ValidationFailure
      Puppet.debug("Cannot parse #{should} as a pip version range")
      return false
    end

    begin
      is_version = PIP_VERSION.parse(is)
    rescue PIP_VERSION::ValidationFailure
      Puppet.debug("Cannot parse #{is} as a pip version")
      return false
    end

    should_range.include?(is_version)
  end

  def self.quote(path)
    if path.include?(" ")
      "\"#{path}\""
    else
      path
    end
  end
  private_class_method :quote
end
