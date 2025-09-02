import java.nio.file.Files
import java.util.Properties
import kotlin.io.path.exists
import kotlin.io.path.isSymbolicLink
import kotlin.io.path.notExists

private object FileMappingHelper {
    /**
     * 配置变量：配置目录的相对路径
     */
    const val CONFIG_PROPERTY_NAME = "APP_CONFIG_DIR"

    /**
     * 配置根目录
     */
    const val CONFIG_SOURCE_ROOT = "config/"

    const val AUTO_GENERATED_BEGIN = "# === AUTO-GENERATED: DO NOT EDIT ==="

    const val AUTO_GENERATED_END = "# === END AUTO-GENERATED ==="

    val AUTO_GENERATED_REGEX = buildString {
        append("(${AUTO_GENERATED_BEGIN.replace(Regex("\\s+"), "\\\\s+")})")
        append("(.*?)")
        append("(${AUTO_GENERATED_END.replace(Regex("\\s+"), "\\\\s+")})")
    }.toRegex(setOf(RegexOption.MULTILINE, RegexOption.DOT_MATCHES_ALL))

    data class Mapping(
        val source: java.nio.file.Path,
        val target: java.nio.file.Path,
    )

    fun doMapping(rootProject: Project) {
        // 按照以下优先级来决定使用哪个配置目录
        val config = rootProject.findProperty(CONFIG_PROPERTY_NAME) as? String // Gradle -P参数
            ?: loadPropertiesOrNull(rootProject.file("local.properties"))?.getProperty(CONFIG_PROPERTY_NAME) // 从local.properties读取
            ?: System.getenv(CONFIG_PROPERTY_NAME) // 环境变量
            ?: error("Please configure the $CONFIG_PROPERTY_NAME property in local.properties or set $CONFIG_PROPERTY_NAME environment variable.")

        val configRoot = rootProject.file(CONFIG_SOURCE_ROOT)
        val configDir = configRoot.resolve(config)
        println("Using config: $configDir")

        // 从mapping.txt读取文件映射关系
        val mappingList = readMappingFile(
            file = configRoot.resolve("mapping.txt"),
            sourceDir = configDir,
            targetDir = rootProject.projectDir
        )

        // 映射后的路径写入.gitignore
        modifyGitIgnoreFile(
            file = rootProject.file(".gitignore"),
            newContent = mappingList.map { it.target.toFile().toRelativeString(rootProject.projectDir).replace(File.separatorChar, '/') }
        )

        // 开始映射
        mappingList.forEach(::updateSymbolicLink)
    }

    private fun loadPropertiesOrNull(file: File): Properties? {
        return if (file.exists()) Properties().apply { file.inputStream().use { load(it) } } else null
    }

    private fun readMappingFile(file: File, sourceDir: File, targetDir: File): List<Mapping> {
        return file.useLines { lines ->
            lines.mapIndexed { index, line ->
                val parts = line.splitToSequence("->")
                    .map { it.trim() }
                    .filter { it.isNotBlank() }
                    .toList()
                if (parts.size != 2) error("Line ${index + 1} invalid format: '$line'")
                val source = sourceDir.resolve(parts[0]).toPath()
                val target = targetDir.resolve(parts[1]).toPath()
                if (source.notExists()) error("Source not found: ${source.toAbsolutePath()}")
                Mapping(source = source, target = target)
            }.toList()
        }
    }

    private fun modifyGitIgnoreFile(file: File, newContent: List<String>) {
        val text = file.readText()
        // 替换 AUTO_GENERATE 之间的内容
        if (text.contains(AUTO_GENERATED_REGEX)) {
            val newText = text.replace(AUTO_GENERATED_REGEX) { matchResult ->
                buildString {
                    appendLine(matchResult.groupValues[1])
                    newContent.forEach { line ->
                        appendLine(line)
                    }
                    append(matchResult.groupValues[3])
                }
            }
            if (text != newText) {
                file.writeText(newText)
                println("Updated .gitignore with mapping rules.")
            } else {
                println(".gitignore already up-to-date.")
            }
        } else {
            val newText = buildString {
                if (!text.endsWith("\n")) {
                    appendLine()
                }
                appendLine(AUTO_GENERATED_BEGIN)
                newContent.forEach { line ->
                    appendLine(line)
                }
                append(AUTO_GENERATED_END)
            }
            file.appendText(newText)
            println("Add mapping rules to .gitignore.")
        }
    }

    private fun updateSymbolicLink(mapping: Mapping) {
        val (source, target) = mapping

        if (target.exists()) {
            if (!target.isSymbolicLink()) error("Target exists but is not a symlink: $target")
            // 检查符号链接是否指向正确的源
            val current = Files.readSymbolicLink(target)
            if (current != source) {
                println("Updating symlink: $source → $target")
                Files.delete(target)  // 删除现有符号链接
                Files.createSymbolicLink(target, source)  // 创建新的符号链接
            } else {
                println("Symlink already correct: $target")
            }
        } else {
            // 确保符号链接的父目录存在
            Files.createDirectories(target.parent)
            // 符号链接存在但是指向的文件不存在，需要先删除原来的链接
            Files.deleteIfExists(target)
            // 创建符号链接
            Files.createSymbolicLink(target, source)
            println("Created symlink: $source → $target")
        }
    }
}

FileMappingHelper.doMapping(rootProject = project)