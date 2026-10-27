#!/usr/bin/env ruby

require "digest"

root = File.expand_path("..", __dir__)
swift_files = Dir[File.join(root, "iosadb/**/*.swift")].sort
english_path = File.join(root, "iosadb/en.lproj/Localizable.strings")
chinese_path = File.join(root, "iosadb/zh-Hans.lproj/Localizable.strings")

def parse_strings(path)
  File.read(path).scan(
    /^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;/
  ).to_h
end

def semantic_key(english_value)
  slug = english_value
    .gsub(/%(\d+\$)?[@dfiu]/i, " value ")
    .gsub(/\\n/, " ")
    .downcase
    .gsub(/[^a-z0-9]+/, "_")
    .gsub(/\A_+|_+\z/, "")
  slug = "localized_text" if slug.empty?
  if slug.length > 64
    slug = "#{slug[0, 54].sub(/_+\z/, "")}_#{Digest::SHA256.hexdigest(english_value)[0, 8]}"
  end
  "text.#{slug}"
end

english = parse_strings(english_path)
chinese = parse_strings(chinese_path)
source_strings = swift_files.flat_map do |path|
  File.read(path).scan(/"((?:\\.|[^"\\])*)"/).flatten.select { |value| value.match?(/\p{Han}/) }
end.uniq

missing = source_strings.reject { |value| english.key?(value) }
unless missing.empty?
  abort "Missing English translations:\n#{missing.join("\n")}"
end

used_keys = {}
mapping = {}
source_strings.sort.each do |source|
  base = semantic_key(english.fetch(source))
  key = base
  if used_keys.key?(key) && used_keys[key] != source
    key = "#{base}_#{Digest::SHA256.hexdigest(source)[0, 8]}"
  end
  used_keys[key] = source
  mapping[source] = key
end

swift_files.each do |path|
  original = File.read(path)
  migrated = original.gsub(/"((?:\\.|[^"\\])*)"/) do |literal|
    value = Regexp.last_match(1)
    replacement = mapping[value]
    replacement ? %("#{replacement}") : literal
  end
  File.write(path, migrated) if migrated != original
end

def append_stable_keys(path, mapping, values)
  existing = parse_strings(path)
  additions = mapping.each_with_object([]) do |(source, key), result|
    next if existing.key?(key)
    result << %("#{key}" = "#{values.fetch(source, source)}";)
  end
  return if additions.empty?

  File.open(path, "a") do |file|
    file.write("\n/* Stable semantic localization keys */\n")
    file.write(additions.sort.join("\n"))
    file.write("\n")
  end
end

append_stable_keys(english_path, mapping, english)
append_stable_keys(chinese_path, mapping, chinese)

remaining = swift_files.flat_map do |path|
  File.readlines(path).each_with_index.each_with_object([]) do |(line, index), result|
    result << "#{path}:#{index + 1}:#{line.strip}" if line.match?(/\p{Han}/)
  end
end
abort "Chinese text remains in Swift sources:\n#{remaining.join("\n")}" unless remaining.empty?

puts "Migrated #{mapping.length} localized source strings to stable semantic keys."
