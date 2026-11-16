#!/usr/bin/env bash
# Contract: .no-mistakes.yaml's commands.test walks the deterministic portable
# lanes through bin/fm-test-run.sh, excludes the live-harness and pinned-hc
# families a gate must never drive, keeps the hermetic hc suite, and disables
# every default-on live guard.
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
           lanes.map { |lane| ["bin/fm-test-run.sh", "--lane", lane, "--exclude-family", "live-harness-optin", "--exclude-family", "hc-pinned"] }
actual = parsed.map(&:last)
raise "commands.test must run the coverage guard then exactly the three portable lanes in order; got #{actual.inspect}" unless actual == expected

parsed.each do |env, argv|
  raise "every executing clause must set FM_LIVE=0 so no default-on guard runs: #{argv.join(' ')}" unless env["FM_LIVE"] == "0"
  raise "commands.test must never select --all: #{argv.join(' ')}" if argv.include?("--all")
  argv.each_cons(2) do |flag, value|
    if flag == "--family" && %w[real-herdr-gated live-harness-optin hc-pinned].include?(value)
      raise "commands.test must never select the #{value} family: #{argv.join(' ')}"
    end
  end
end

runner = File.join(root, "bin/fm-test-run.sh")
bad_families = %w[live-harness-optin real-herdr-gated hc-pinned]
bad_paths = bad_families.flat_map { |family| list_selected(runner, ["--family", family]) }.uniq
selected_all = []

parsed.drop(1).each do |_env, argv|
  lane = argv[argv.index("--lane") + 1]
  selected = list_selected(runner, argv.drop(1))
  selected_all.concat(selected)
  leaked = selected & bad_paths
  raise "lane #{lane} must not select the live-harness, real-Herdr, or pinned hc families, got: #{leaked.join(', ')}" unless leaked.empty?
end

hermetic_hc = "tests/fm-backend-hc.test.sh"
raise "commands.test must keep the hermetic hc suite gated: #{hermetic_hc} was not selected" unless selected_all.include?(hermetic_hc)

witness = "tests/fm-backend-t3code.test.sh"
raise "commands.test must select the default-on guard witness #{witness}" unless selected_all.include?(witness)

puts "commands.test runs the exact portable lane sequence, excludes the live-harness and pinned-hc families while keeping the hermetic hc suite, and disables default-on guards"
RUBY
  local witness_name=tests/fm-backend-t3code.test.sh witness_out
  # Run the selected suite's own default-on guard; FM_LIVE=0 must short-circuit it.
  witness_out=$(FM_LIVE=0 FM_TEST_ONLY=t3_verify_live_codex_env bash "$ROOT/$witness_name" 2>&1) \
    || fail "$witness_name carries a selected default-on guard that must be inert under FM_LIVE=0"$'\n'"$witness_out"
  case "$witness_out" in
    *"skip: live: disabled by FM_LIVE=0"*) ;;
    *) fail "$witness_name's default-on guard must report the FM_LIVE=0 skip; got: $witness_out" ;;
  esac
  pass "no-mistakes commands.test runs the portable lanes while the selected $witness_name default-on guard skips under FM_LIVE=0"
}

test_nm_commands_test_runs_the_portable_lanes
