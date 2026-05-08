require 'git'
desc 'Run integration tests for frontend library'
task :integration do
  rails_repo_dir = File.expand_path(".")
  react_repo_dir = File.expand_path("tmp/makerspace-react")
  react_repo_url = ENV["REACT_REPO_URL"] || "https://github.com/thannemann/makerspace-react.git"
  react_branch   = ENV["REACT_BRANCH"] or raise "REACT_BRANCH environment variable must be set (e.g. master, test_fixes)"

  puts "=" * 60
  puts "  INTEGRATION TEST BUILD INFO"
  puts "=" * 60
  puts "  Rails branch : #{`git rev-parse --abbrev-ref HEAD`.strip}"
  puts "  React repo   : #{react_repo_url}"
  puts "  React branch : #{react_branch}"
  puts "  Timestamp    : #{Time.now.utc.iso8601}"
  puts "=" * 60

  if !File.directory?(react_repo_dir)
    puts "Cloning React repo..."
    react_git = Git.clone(react_repo_url, react_repo_dir, log: Logger.new("/dev/null"))
  else
    puts "React repo exists, opening..."
    react_git = Git.open(react_repo_dir, log: Logger.new("/dev/null"))
    react_git.pull
  end

  react_git.fetch
  puts "Checking out React branch: #{react_branch}"
  react_git.checkout(react_branch)
  puts "React HEAD: #{react_git.log(1).first.sha}"

  Dir.chdir(react_repo_dir)
  system("PORT=3035 yarn && PORT=3035 yarn build") || exit(-1)
  FileUtils.mkdir_p(File.join(rails_repo_dir, "app/assets/builds"))
  FileUtils.cp(File.join(react_repo_dir, "dist/makerspace-react.js"), File.join(rails_repo_dir, "app/assets/builds"))
  FileUtils.cp(File.join(react_repo_dir, "dist/makerspace-react.css"), File.join(rails_repo_dir, "app/assets/builds"))
  Dir.chdir(rails_repo_dir)
  server_started = system("RAILS_ENV=test rake 'db:db_reset[subscriptions,payment_methods]' && RAILS_ENV=test rails runner db/seeds_rental_spots.rb && RAILS_ENV=test rails s -b 0.0.0.0 -p 3035 -d")
  if server_started
    Dir.chdir(react_repo_dir)
    tests_pass = system("PORT=3035 HEADLESS=true RAILS_DIR=#{rails_repo_dir} yarn e2e")
    unless tests_pass
      puts("--------------- TESTS FAILED ---------------")
      exit(-1)
    end
  else
    puts("--------------- FAILED STARTING SERVER ---------------")
    exit(-1)
  end
end

task :start_test_server do
  server_started = system("RAILS_ENV=test rake db:db_reset && RAILS_ENV=test rails s -b 0.0.0.0 -p 3035")
  unless server_started
    puts("--------------- FAILED STARTING SERVER ---------------")
    exit(-1)
  end
end
