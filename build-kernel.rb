require 'bundler/inline'

KERNEL_TAG = 'KAWGRR'
KERNEL_NUMBER = '1002'

# https://github.com/openzfs/zfs/releases
ZFS_VERSION = '2.2.7'
# Check kernel versions at: https://kernel.org
ZFS_SUPPORTED_KERNEL = '6.12'

# Building custom kernels for Fedora with help from:
# - https://fedoraproject.org/wiki/Building_a_custom_kernel
# - https://openzfs.github.io/openzfs-docs/Developer%20Resources/Building%20ZFS.html

gemfile do
  source 'https://rubygems.org'
  gem 'pry'
  gem 'rb-readline'
end

puts 'Gems locked and loaded!'

require 'open3'

def run_command(command, input = nil, allowed_exit_codes = [0])
  process, status, stdout, stderr = Open3.popen3(command) do |stdin, stdout, stderr, wait_thread|
    stdin.puts(input) if input
    stdin.close

    threads = {}.tap do |it|
      it[:stdout] = Thread.new do
        output = []
        stdout.each do |l|
          output << l
        end
        Thread.current[:output] = output.join
      end

      it[:stderr] = Thread.new do
        output = []
        stderr.each do |l|
          output << l
        end
        Thread.current[:output] = output.join
      end
    end
    threads.values.map(&:join)

    [wait_thread.value, wait_thread.value.exitstatus, threads[:stdout][:output], threads[:stderr][:output]]
  end

  unless allowed_exit_codes.include?(status)
    puts 'stdout:'
    puts stdout.strip
    puts
    puts 'stderr:'
    puts stderr.strip
    puts
    raise "`#{command}` failed with status=#{status}"
  end

  [status, stdout.strip, stderr.strip]
end

# FETCH EXPLODED FEDORA KERNEL TREE
# -----------------------------------------------------------------------------
run_command('git clone https://gitlab.com/cki-project/kernel-ark.git') unless Dir.exist?('kernel-ark')

Dir.chdir('kernel-ark') do
  run_command('git checkout os-build')
  run_command('git pull')
  _, tags, = run_command('git tag --list')
  tags = tags.split("\n")

  # Fedora prepends their tags with "kernel-"
  tags = tags.select { |t| t.start_with?("kernel-#{ZFS_SUPPORTED_KERNEL}") }

  # Get rid of "rc" releases
  tags = tags.reject { |t| t.include?('.rc') }

  # Get rid of "elrdy" releases
  tags = tags.reject { |t| t.include?('.elrdy') }

  # Get rid of "fc33" releases
  tags = tags.reject { |t| t.include?('.fc33') }

  # Grab latest tag
  version_capture = /\Akernel-(\d+.\d+.\d+-\d{1,3})\z/
  tag = tags.grep(version_capture).sort_by do |version|
    Gem::Version.new(version.match(version_capture).captures.first)
  end.last
  raise 'No tag found' unless tag

  # Pick the last version
  puts
  puts "Building on top of #{tag}"
  run_command("git checkout #{tag}")
end

# SETUP TMP KERNEL
# -----------------------------------------------------------------------------
run_command('rm -rf tmpkernel') if Dir.exist?('tmpkernel')
run_command('cp -ar kernel-ark tmpkernel')

Dir.chdir('tmpkernel') do
  #  run_command("rm -rf .git*")
  run_command('make mrproper')
  run_command('make ARCH=x86_64 oldconfig')
  run_command('make prepare')

  run_command('rm .config')
  run_command('make FLAVOR=fedora dist-configs-arch')
  run_command('cp redhat/configs/kernel-*-x86_64.config .config')
end

# BUILD ZFS
# -----------------------------------------------------------------------------
run_command('git clone https://github.com/zfsonlinux/zfs') unless Dir.exist?('zfs')

Dir.chdir('zfs') do
  run_command('git clean -fx')
  run_command('git checkout master')
  run_command('git pull')
  _, tags, = run_command('git tag --list')
  tags = tags.split("\n")

  # Get rid of "rc" releases
  tags = tags.reject { |t| t.include?('-rc') }

  # Set tag
  tag = "zfs-#{ZFS_VERSION}"

  puts "Building #{tag} (https://github.com/openzfs/zfs/releases/tag/#{tag})"
  run_command("git checkout #{tag}")
  run_command('sh autogen.sh')

  configure = [
    './configure',
    '--enable-linux-builtin',
    '--with-linux=../tmpkernel',
    '--with-linux-obj=../tmpkernel'
  ]
  run_command(configure.join(' '))
  run_command('./copy-builtin ../tmpkernel')
end

# BUILD KERNEL
# -----------------------------------------------------------------------------
Dir.chdir('tmpkernel') do
  puts
  puts 'Adding custom config flags'
  config = File.open('.config').read
  config_options = [
    'CONFIG_VFIO=m',
    'CONFIG_VFIO_IOMMU_TYPE1=m',
    'CONFIG_VFIO_PCI=m',
    'CONFIG_VFIO_VIRQFD=y',
    'CONFIG_KVM=y',
    'CONFIG_KVM_INTEL=y',
    'CONFIG_ZFS=y',
    'CONFIG_USB_XHCI_HCD=m',
    'CONFIG_USB_XHCI_PCI=m'
  ]

  config_options.each do |config_option|
    if config.include?(config_option)
      puts "- #{config_option} already set"
    elsif config_option.end_with?('=y') && config.include?(config_option.gsub('=y', '=m'))
      puts "- #{config_option} is a module, changing it to built-in"
      config_option_m = config_option.gsub('=y', '=m')
      run_command("sed -i \"s/#{config_option_m}/#{config_option}/\" .config")
    elsif config_option.end_with?('=m') && config.include?(config_option.gsub('=m', '=y'))
      puts "- #{config_option} is built-in, changing it to module"
      config_option_y = config_option.gsub('=m', '=y')
      run_command("sed -i \"s/#{config_option_y}/#{config_option}/\" .config")
    else
      puts "- #{config_option} is not set, adding it"
      File.open('.config', 'a') do |f|
        f.write(config_option)
      end
    end
  end

  # This cleans up and reorders the .config-file after our patching
  run_command('make ARCH=x86_64 oldconfig')

  puts
  puts 'Verifying config flags'

  config = File.open('.config').read
  config_options.each do |config_option|
    raise "#{config_option} not found in .config" unless config.include?(config_option)
  end
  puts '.. all config flags looks good!'
  puts

  puts "Building kernel #{KERNEL_TAG}-#{KERNEL_NUMBER}"
  # run_command("make bzImage ARCH=x86_64 EXTRAVERSION=-#{KERNEL_TAG} LOCALVERSION=-#{KERNEL_NUMBER} -j `nproc`")
  # run_command("make modules ARCH=x86_64 EXTRAVERSION=-#{KERNEL_TAG} LOCALVERSION=-#{KERNEL_NUMBER} -j `nproc`")
  run_command("make binrpm-pkg EXTRAVERSION=-#{KERNEL_TAG} LOCALVERSION=-#{KERNEL_NUMBER} -j `nproc`")
end

kernel_rpm = Dir.glob('tmpkernel/rpmbuild/RPMS/x86_64/*.rpm').select do |e|
  File.file? e
end.select { |f| f =~ %r{/kernel-\d+\.\d+} }.first

# FINALIZE
# -----------------------------------------------------------------------------
puts 'The kernel is now built, you can install it by typing:'
puts "$ rpm -ivh #{kernel_rpm}"
puts

status, installed_rpms, = run_command('rpm -qa | grep KAWGRR', nil, [0, 1])
if status.zero?
  puts 'Installed kernels:'
  installed_rpms.lines.each do |kernel|
    puts "#{kernel}"
  end
  puts
  puts 'You can delete them by typing: rpm -e PACKAGE_NAME'
end

unless File.exist?('/etc/dkms/no-autoinstall')
  puts
  puts "/etc/dkms/no-autoinstall doesn't exist, you should consider creating it"
end

# $ sudo grubby --set-default /boot/vmlinuz-5.4.1
# You can confirm the details with the following commands:
# grubby --info=ALL | more
# grubby --default-index
# grubby --default-kernel
# puts "grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg"

# dracut --force --no-hostonly
