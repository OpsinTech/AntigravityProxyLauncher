#pragma once
#include <sys/stat.h>
#include <pwd.h>
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <ctime>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>
#include <unistd.h>

namespace Core {
enum class LogLevel { Debug, Info, Warn, Error };

class Logger {
private:
  static FILE *s_file;
  static std::mutex s_mtx;
  static LogLevel s_level;           // 当前日志级别
  static bool s_fileLoggingEnabled;  // 是否启用文件日志（默认false提升性能）

  static int LevelToInt(LogLevel level) {
    switch (level) {
    case LogLevel::Debug: return 0;
    case LogLevel::Info:  return 1;
    case LogLevel::Warn:  return 2;
    case LogLevel::Error: return 3;
    default: return 4;
    }
  }

public:
  static void Init(const std::string &path = "") {
    std::lock_guard<std::mutex> lock(s_mtx);
    if (s_file != nullptr)
      return; // 已初始化

    // 默认情况下不启用文件日志，仅输出到 stderr
    // 如需文件日志，通过环境变量 ANTIGRAVITY_LOG_FILE=1 开启
    const char *envFile = getenv("ANTIGRAVITY_LOG_FILE");
    s_fileLoggingEnabled = (envFile && (envFile[0] == '1' || envFile[0] == 't' || envFile[0] == 'T'));

    const char *envLevel = getenv("ANTIGRAVITY_LOG_LEVEL");
    if (envLevel != nullptr) {
      SetLevelFromString(envLevel);
    }

    if (!s_fileLoggingEnabled) {
      return; // 不启用文件日志，提升性能
    }

    std::string logPath;
    const char *envPath = getenv("ANTIGRAVITY_LOG_PATH");
    if (envPath != nullptr && envPath[0] != '\0') {
      logPath = envPath;
    } else {
      logPath = path;
    }

    if (logPath.empty()) {
      // 默认路径到 ~/.config/antigravity，避免沙箱 /tmp 权限问题
      const char *home = getenv("HOME");
      if (!home) home = "/tmp"; // fallback
      char buf[512];
      snprintf(buf, sizeof(buf), "%s/.config/antigravity/antigravity_proxy.%d.log", home, getpid());
      logPath = buf;
    }
    
    // 以追加模式打开
    s_file = fopen(logPath.c_str(), "a");
    if (s_file == nullptr) {
      const char *tmpDir = getenv("TMPDIR");
      if (tmpDir != nullptr && tmpDir[0] != '\0') {
        std::string fallbackPath = tmpDir;
        if (fallbackPath.back() != '/') {
          fallbackPath.push_back('/');
        }
        fallbackPath += "antigravity_proxy." + std::to_string(getpid()) + ".log";
        s_file = fopen(fallbackPath.c_str(), "a");
      }
    }

    if (s_file != nullptr) {
      // 设置行缓冲
      setvbuf(s_file, nullptr, _IOLBF, 0);
    } else {
      fprintf(stderr, "[antigravity] failed to open runtime log file\n");
    }
  }

  static void SetLevelFromString(const std::string &levelStr) {
    std::string lower = levelStr;
    const char *envLevel = getenv("ANTIGRAVITY_LOG_LEVEL");
    if (envLevel != nullptr && envLevel[0] != '\0') {
      lower = envLevel;
    }
    
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    
    if (lower == "debug") {
      s_level = LogLevel::Debug;
    } else if (lower == "info") {
      s_level = LogLevel::Info;
    } else if (lower == "warn" || lower == "warning") {
      s_level = LogLevel::Warn;
    } else if (lower == "error") {
      s_level = LogLevel::Error;
    } else {
      s_level = LogLevel::Warn; // 默认 warn
    }
  }

  static bool IsEnabled(LogLevel level) {
    return LevelToInt(level) >= LevelToInt(s_level);
  }

  static void Log(LogLevel level, const std::string &msg) {
    // 快速路径：级别不够直接返回
    if (!IsEnabled(level))
      return;

    time_t now = time(nullptr);
    struct tm tstruct;
    char buf[80];
    localtime_r(&now, &tstruct);
    strftime(buf, sizeof(buf), "%Y-%m-%d %X", &tstruct);

    const char *levelStr = LevelToString(level);
    int pid = getpid();

    // 输出到 stderr（仅当文件日志未启用时，避免污染宿主应用输出）
    if (!s_fileLoggingEnabled) {
      fprintf(stderr, "[%s] [%d] %s %s\n", buf, pid, levelStr, msg.c_str());
    }

    // 文件日志（如果启用）- 减少锁持有时间，先格式化字符串
    if (s_fileLoggingEnabled && s_file != nullptr) {
      char line[512];
      int len = snprintf(line, sizeof(line), "[%s] [%d] %s %s\n",
                         buf, pid, levelStr, msg.c_str());
      if (len > 0 && len < (int)sizeof(line)) {
        std::lock_guard<std::mutex> lock(s_mtx);
        if (s_file != nullptr) {
          fwrite(line, 1, len, s_file);
        }
      }
    }
  }

  static void Debug(const std::string &msg) { Log(LogLevel::Debug, msg); }
  static void Info(const std::string &msg) { Log(LogLevel::Info, msg); }
  static void Warn(const std::string &msg) { Log(LogLevel::Warn, msg); }
  static void Error(const std::string &msg) { Log(LogLevel::Error, msg); }

  /// 返回 ~/.config/antigravity/<name> 的完整路径（沙箱安全，自动 mkdir）
  static std::string LogPath(const std::string &name) {
    std::string home;
    const char *envHome = getenv("HOME");
    if (envHome) {
      home = envHome;
    } else {
      struct passwd *pw = getpwuid(getuid());
      if (pw) home = pw->pw_dir;
    }
    std::string dir = home + "/.config/antigravity";
    mkdir(dir.c_str(), 0755);
    return dir + "/" + name;
  }

private:
  static const char *LevelToString(LogLevel level) {
    switch (level) {
    case LogLevel::Debug:
      return "[DEBUG]";
    case LogLevel::Info:
      return "[INFO] ";
    case LogLevel::Warn:
      return "[WARN] ";
    case LogLevel::Error:
      return "[ERROR]";
    default:
      return "[UNKNOWN]";
    }
  }
};

// 静态成员定义
FILE *Logger::s_file = nullptr;
std::mutex Logger::s_mtx;
LogLevel Logger::s_level = LogLevel::Warn;  // 默认 warn，减少日志开销
bool Logger::s_fileLoggingEnabled = false;   // 默认关闭文件日志

} // namespace Core
