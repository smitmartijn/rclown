require "find"

# All filesystem access for local targets goes through this boundary. The root
# must be dedicated to Rclown: concurrent changes by other writers cannot be
# made safe by a preflight check followed by an external rclone process.
class Provider::LocalPath
  class Error < Rclone::Error; end

  def initialize(root)
    @root = root
  end

  def root!
    unless @root.present? && @root.start_with?("/") && !@root.match?(/[[:cntrl:]]/)
      raise Error, "Base path must be an absolute directory path"
    end

    canonical = File.realpath(@root)
    raise Error, "Base path cannot be the filesystem root" if canonical == "/"
    raise Error, "Base path must not contain symlinks; use #{canonical}" unless File.expand_path(@root) == canonical
    check_directory!(canonical)
    canonical
  rescue SystemCallError => e
    raise Error, "Cannot access base directory #{@root}: #{e.message}"
  end

  def resolve!(path, retention: false, inspect_tree: false)
    root = root!
    parts = path.to_s.split("/", -1)
    if path.blank? || path.start_with?("/") || path.match?(/[[:cntrl:]\\]/) || parts.any? { |part| [ "", ".", ".." ].include?(part) }
      raise Error, "Destination path must be a nonempty relative path without dot segments or empty components"
    end
    if !retention && parts.first.downcase == ".deleted"
      raise Error, "Destination path cannot use the reserved .deleted directory"
    end

    target = File.expand_path(File.join(root, path))
    raise Error, "Destination path escapes the base directory" unless target.start_with?(root + "/")

    current = root
    parts.each do |part|
      current = File.join(current, part)
      stat = stat_if_present(current)
      break unless stat
      check_entry!(current, stat)
      check_directory!(current)
      unless File.realpath(current).start_with?(root + "/")
        raise Error, "Destination path escapes the base directory"
      end
    end

    if inspect_tree && File.directory?(target)
      Find.find(target, ignore_error: false) do |entry|
        stat = File.lstat(entry)
        check_entry!(entry, stat)
        check_directory!(entry) if stat.directory?
      end
    end
    target
  rescue SystemCallError => e
    raise Error, "Cannot access destination: #{e.message}"
  end

  private
    def stat_if_present(path)
      File.lstat(path)
    rescue Errno::ENOENT
      nil
    end

    def check_directory!(path)
      raise Error, "#{path} is not a directory" unless File.directory?(path)
      unless File.readable?(path) && File.writable?(path) && File.executable?(path)
        raise Error, "Directory #{path} must be readable, writable and searchable by the Rclown process (permission denied)"
      end
    end

    def check_entry!(path, stat)
      raise Error, "Symlinks are not allowed in local destinations: #{path}" if stat.symlink?
      raise Error, "Hard-linked files are not allowed in local destinations: #{path}" if stat.file? && stat.nlink > 1
      raise Error, "Special files are not allowed in local destinations: #{path}" unless stat.file? || stat.directory?
    end
end
