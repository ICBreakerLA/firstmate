#!/usr/bin/env bash
# Contract: .no-mistakes.yaml's commands.test walks the deterministic portable
# lanes through bin/fm-test-run.sh, excludes the live-harness and hc families a
# gate must never drive, and disables every default-on live guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_commands_test_runs_the_portable_lanes() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  ruby -ryaml -rshellwords -ropen3 - "$NM" "$ROOT" <<'RUBY' || fail "no-mistakes commands.test contract"
doc_path, root = ARGV

def split_clauses(command)
  parts = []
  buffer = +""
  quote = nil
  index = 0
  while index < command.length
    char = command[index]
    if quote
      buffer << char
      if char == quote
        quote = nil
      elsif char == "\\" && quote == '"' && index + 1 < command.length
        index += 1
        buffer << command[index]
      end
    elsif char == '"' || char == "'"
      quote = char
      buffer << char
    elsif char == "&" && command[index + 1] == "&"
      parts << buffer.strip
      buffer = +""
      index += 1
    else
      buffer << char
    end
    index += 1
  end
  parts << buffer.strip
  parts.reject(&:empty?)
end

def split_clause(clause)
  tokens = Shellwords.shellsplit(clause)
  env = {}
  while (token = tokens.first) && token =~ /\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/m
    env[Regexp.last_match(1)] = Regexp.last_match(2)
    tokens.shift
  end
  [env, tokens]
end

def list_selected(runner, args)
  output, status = Open3.capture2(runner, "--list", *args)
  raise "#{runner} --list #{args.join(' ')} failed" unless status.success?
  output.lines.map(&:chomp).reject(&:empty?)
end

doc = YAML.load_file(doc_path) || {}
commands = doc["commands"]
command = commands.is_a?(Hash) ? commands["test"] : nil
raise "commands.test must be present: the local no-mistakes gate owns broad deterministic regression" if command.nil? || command == false || command.to_s.strip.empty?

parsed = split_clauses(command.to_s).map { |clause| split_clause(clause) }
lanes = %w[portable-parallel-1 portable-parallel-2 portable-serial]
expected = [["bin/fm-test-run.sh", "--check-coverage"]] +
           lanes.map { |lane| ["bin/fm-test-run.sh", "--lane", lane, "--exclude-family", "live-harness-optin", "--exclude-family", "hc"] }
actual = parsed.map(&:last)
raise "commands.test must run the coverage guard then exactly the three portable lanes in order; got #{actual.inspect}" unless actual == expected

parsed.each do |env, argv|
  raise "every executing clause must set FM_LIVE=0 so no default-on guard runs: #{argv.join(' ')}" unless env["FM_LIVE"] == "0"
  raise "commands.test must never select --all: #{argv.join(' ')}" if argv.include?("--all")
  argv.each_cons(2) do |flag, value|
    if flag == "--family" && %w[real-herdr-gated live-harness-optin hc].include?(value)
      raise "commands.test must never select the #{value} family: #{argv.join(' ')}"
    end
  end
end

runner = File.join(root, "bin/fm-test-run.sh")
bad_families = %w[live-harness-optin real-herdr-gated hc]
bad_paths = bad_families.flat_map { |family| list_selected(runner, ["--family", family]) }.uniq

parsed.drop(1).each do |_env, argv|
  lane = argv[argv.index("--lane") + 1]
  selected = list_selected(runner, argv.drop(1))
  leaked = selected & bad_paths
  raise "lane #{lane} must not select the live-harness, real-Herdr, or hc families, got: #{leaked.join(', ')}" unless leaked.empty?
  live_guards = selected.select do |path|
    File.foreach(File.join(root, path)).any? { |line| line =~ /\Afm_live_gate\s+default-on/ }
  end
  raise "lane #{lane} must not select a live guard script, got: #{live_guards.join(', ')}" unless live_guards.empty?
end

puts "commands.test runs the exact portable lane sequence, excludes the live and hc families, and disables default-on guards"
RUBY
  pass "no-mistakes commands.test runs the portable lanes without live or hc coverage"
}

test_nm_commands_test_runs_the_portable_lanes
