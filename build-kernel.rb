require 'bundler/inline'

# Building custom kernels for Fedora with help from:
# - https://fedoraproject.org/wiki/Building_a_custom_kernel
# - https://openzfs.github.io/openzfs-docs/Developer%20Resources/Building%20ZFS.html

gemfile do
  source 'https://rubygems.org'
  gem 'pry'
    gem 'rb-readline'
end

puts 'Gems installed and loaded!'

require 'open3'

def run_command(command, input = nil, allowed_exit_codes = [0])
  process, status, stdout, stderr = Open3.popen3(command) do |stdin, stdout, stderr, wait_thread|
    if input
      stdin.puts(input)
    end
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
    puts "stdout:"
    puts stdout.strip
    puts
    puts "stderr:"
    puts stderr.strip
    puts
    raise "`#{command}` failed with status=#{status}"
  end

  return [status, stdout.strip, stderr.strip]
end

# FIND CURRENT FEDORA RELEASE
# -----------------------------------------------------------------------------
os_release = File.open("/etc/os-release").read
raise "No VERSION_ID in /etc/os-release" unless os_release.include?("VERSION_ID")
fedora_release = os_release.tap do |it|
  break "fc" + it.split("\n").select{|variable| variable.start_with?("VERSION_ID=")}.first.split("=").last
end

# FETCH EXPLODED FEDORA KERNEL TREE
# -----------------------------------------------------------------------------
unless Dir.exists?("fedora")
  run_command("git clone git://git.kernel.org/pub/scm/linux/kernel/git/jwboyer/fedora.git")
end

Dir.chdir("fedora") do
  run_command("git checkout master")
  run_command("git pull")
  _, tags, _ = run_command("git tag --list")
  tags = tags.split("\n")

  # Fedora prepends their tags with "kernel-"
  tags = tags.select{|t| t.start_with?("kernel-")}

  # Fedora includes the Fedora release number in the tags like "fc30" or "fc31"
  tags = tags.select{|t| t.end_with?(fedora_release)}

  # Get rid of "rc" releases
  tags = tags.reject{|t| t.include?(".rc")}

  # Grab latest tag
  tag = tags.last

  # Pick the last version
  puts "Building on top of #{tag}"
  run_command("git checkout #{tag}")
end

# SETUP TMP KERNEL
# -----------------------------------------------------------------------------
if Dir.exists?("tmpkernel")
  run_command("rm -rf tmpkernel")
end
run_command("cp -ar fedora tmpkernel")

Dir.chdir("tmpkernel") do
  run_command("rm -rf .git*")
  run_command("make mrproper")
  run_command("make ARCH=x86_64 oldconfig")
  run_command("make prepare")
end

# BUILD KERNEL
# -----------------------------------------------------------------------------
Dir.chdir("tmpkernel") do
  run_command("sed -i \"s/CONFIG_USB_XHCI_HCD=y/CONFIG_USB_XHCI_HCD=m/\" .config")
  run_command("sed -i \"s/CONFIG_USB_XHCI_PCI=y/CONFIG_USB_XHCI_PCI=m/\" .config")

  # This cleans up and reorders the .config-file after our changes
  run_command("make ARCH=x86_64 oldconfig")

  config = File.open(".config").read
  raise "CONFIG_USB_XHCI_HCD=m not found in .config" unless config.include?("CONFIG_USB_XHCI_HCD=m")
  raise "CONFIG_USB_XHCI_PCI=m not found in .config" unless config.include?("CONFIG_USB_XHCI_PCI=m")

  kernel_tag = "KAWGRR"
  kernel_number = "9999"
  run_command("make bzImage EXTRAVERSION=-#{kernel_tag} LOCALVERSION=-#{kernel_number} -j `nproc`")
  run_command("make modules EXTRAVERSION=-#{kernel_tag} LOCALVERSION=-#{kernel_number} -j `nproc`")
end

# FINALIZE
# -----------------------------------------------------------------------------
puts "The kernel is now built, you can install it by typing:"
puts
puts "cd tmpkernel"
puts "sudo make modules_install"
puts "sudo make install"
puts
puts "Verify installation with grubby:"
puts
puts "grubby --info=ALL | more"
puts "grubby --default-index"
puts "grubby --default-kernel"
