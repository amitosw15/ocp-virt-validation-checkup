package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

var (
	resultsDir = flag.String("results-dir", "", "Directory containing test suite log files")
	stdout     = flag.Bool("stdout", false, "Also output progress to stdout (default: false, always writes to log file)")
	skipDryRun = flag.Bool("skip-dry-run", false, "Skip dry-run discovery and use dynamic total discovery instead")
	verbose    = flag.Bool("verbose", false, "Enable verbose logging for debugging (shows every line processed)")
)

var (
	specRegex = regexp.MustCompile(`Will run (\d+) of \d+ specs`)
	// For pytest (tier2 tests) - matches selected test count (excluding deselected/skipped)
	// Format: "collected X items / Y deselected / Z selected"
	pytestRegex = regexp.MustCompile(`collected \d+ items / \d+ deselected / (\d+) selected`)
	// Fallback for when there are no deselected tests: "collected X items"
	pytestRegexSimple = regexp.MustCompile(`collected (\d+) items$`)
	// Ginkgo final summary: "Ran X of Y Specs in Z seconds" (case-insensitive for specs/Specs)
	ginkgoRanRegex = regexp.MustCompile(`(?i)^Ran \d+.+[Ss]pecs? in .+seconds?`)
	// Ginkgo final status: "FAIL! -- X Passed | Y Failed" or "PASS! -- X Passed | Y Failed"
	ginkgoStatusRegex = regexp.MustCompile(`^(PASS|FAIL)! -- \d+ Passed \|`)
	// Pytest short test summary info (with or without = borders)
	pytestSummaryRegex = regexp.MustCompile(`(?:=+ )?short test summary info`)
	// Pytest final line: "X passed, Y failed in Z seconds" or "= X passed in Z seconds ="
	pytestFinalRegex = regexp.MustCompile(`\d+ passed.* in .+seconds?`)
	// Global logger for progress output
	logger  *log.Logger
	logFile *os.File
	// Previous progress state for change detection
	previousProgress *ProgressState
	// Pre-discovered test totals from dry-run
	preDiscoveredTotals map[string]int
	// Last update timestamp for rate limiting
	lastUpdateTime time.Time
)

// TestSuite represents a single test suite being monitored
type TestSuite struct {
	Name      string
	LogFile   string
	Total     int
	Completed int
	Passed    int
	Failed    int
	Finished  bool
	StartTime time.Time
	EndTime   time.Time
	Reader    *bufio.Reader
	File      *os.File
}

// ProgressState represents the current progress state for change detection
type ProgressState struct {
	OverallTotal     int
	OverallCompleted int
	OverallPercent   int
	ActiveSuites     int
	SuiteProgress    map[string]SuiteState
}

// SuiteState represents the progress state of a single test suite
type SuiteState struct {
	Total     int
	Completed int
	Passed    int
	Failed    int
	Percent   int
	Finished  bool
	Duration  time.Duration
}

// DuplicateFilterWriter wraps an io.Writer and filters out consecutive duplicate lines
type DuplicateFilterWriter struct {
	writer   io.Writer
	lastLine string
	mutex    sync.Mutex
}

// NewDuplicateFilterWriter creates a new DuplicateFilterWriter
func NewDuplicateFilterWriter(writer io.Writer) *DuplicateFilterWriter {
	return &DuplicateFilterWriter{
		writer: writer,
	}
}

// Write implements io.Writer interface and filters out duplicate lines
func (d *DuplicateFilterWriter) Write(p []byte) (n int, err error) {
	d.mutex.Lock()
	defer d.mutex.Unlock()

	line := string(p)

	// If this line is the same as the last line, don't write it
	if line == d.lastLine {
		// Return the length as if we wrote it to satisfy the io.Writer interface
		return len(p), nil
	}

	// Update last line and write to underlying writer
	d.lastLine = line
	return d.writer.Write(p)
}

// setupLogging configures logging to file and optionally to stdout with duplicate filtering
func setupLogging() error {
	var err error
	logFile, err = os.OpenFile("/tmp/progress_watcher.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return fmt.Errorf("failed to open log file: %v", err)
	}

	// Always write to log file with duplicate filtering, conditionally include stdout
	var writers []io.Writer
	writers = append(writers, NewDuplicateFilterWriter(logFile))

	if *stdout {
		writers = append(writers, NewDuplicateFilterWriter(os.Stdout))
	}

	multiWriter := io.MultiWriter(writers...)
	logger = log.New(multiWriter, "[PROGRESS] ", log.LstdFlags)

	return nil
}

func main() {
	flag.Parse()

	if *resultsDir == "" {
		fmt.Fprintln(os.Stderr, "Missing required --results-dir argument")
		os.Exit(1)
	}

	// Set up logging to file and stdout
	if err := setupLogging(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to setup logging: %v\n", err)
		os.Exit(1)
	}
	defer func() {
		if logFile != nil {
			logFile.Close()
		}
	}()

	logger.Println("Progress watcher starting...")

	clientset := getClientset()

	// Initialize pre-discovered totals
	preDiscoveredTotals = make(map[string]int)

	// Discover test totals upfront using dry-run (unless skipped)
	if !*skipDryRun {
		// Log storage configuration status
		storageConfigFile := os.Getenv("KUBEVIRT_STORAGE_CONFIGURATION_FILE")
		testingConfigFile := os.Getenv("KUBEVIRT_TESTING_CONFIGURATION_FILE")
		storageClass := os.Getenv("STORAGE_CLASS")

		logger.Printf("Storage configuration environment:")
		logger.Printf("  KUBEVIRT_STORAGE_CONFIGURATION_FILE: %s\n", storageConfigFile)
		logger.Printf("  KUBEVIRT_TESTING_CONFIGURATION_FILE: %s\n", testingConfigFile)
		logger.Printf("  STORAGE_CLASS: %s\n", storageClass)

		// Check if custom storage config file exists (only for custom configs)
		if storageConfigFile != "" {
			isCustom := os.Getenv("KUBEVIRT_STORAGE_CONFIG_IS_CUSTOM")
			if isCustom == "true" {
				configPath := filepath.Join(*resultsDir, storageConfigFile)
				if fileExists(configPath) {
					logger.Printf("Using custom storage config file: %s\n", configPath)
				} else {
					logger.Printf("Warning: Custom storage config file not found at %s\n", configPath)
				}
			} else {
				logger.Printf("Using predefined storage config: %s (from scripts directory)\n", storageConfigFile)
			}
		} else {
			logger.Printf("No KUBEVIRT_STORAGE_CONFIGURATION_FILE set, will use KUBEVIRT_TESTING_CONFIGURATION_FILE or defaults\n")
		}

		logger.Println("Running dry-run discovery to determine total test counts...")

		// Run with timeout to avoid hanging
		done := make(chan bool, 1)
		go func() {
			preDiscoveredTotals = discoverTestTotalsByDryRun(*resultsDir)
			done <- true
		}()

		select {
		case <-done:
			totalTests := 0
			for _, count := range preDiscoveredTotals {
				totalTests += count
			}
			logger.Printf("Pre-discovery complete: %d total tests across %d suites\n", totalTests, len(preDiscoveredTotals))
		case <-time.After(2 * time.Minute):
			logger.Println("Dry-run discovery timed out after 2 minutes, falling back to dynamic discovery")
			preDiscoveredTotals = make(map[string]int) // Reset to empty
		}
	} else {
		logger.Println("Skipping dry-run discovery, will use dynamic total discovery")
	}

	// Set up signal handling for graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Discover test suites by looking for log files
	suites := discoverTestSuites(*resultsDir)
	if len(suites) == 0 {
		logger.Println("No test suite log files found. Waiting for test suites to start...")
	}

	// Cleanup function
	cleanup := func() {
		logger.Println("Cleaning up...")
		for _, suite := range suites {
			if suite.File != nil {
				suite.File.Close()
			}
		}
	}

	// Main monitoring loop
	for {
		select {
		case <-sigChan:
			logger.Println("Received shutdown signal")
			cleanup()
			os.Exit(0)
		default:
			// Rediscover suites in case new ones start
			newSuites := discoverTestSuites(*resultsDir)
			for _, newSuite := range newSuites {
				found := false
				for _, existing := range suites {
					if existing.Name == newSuite.Name {
						found = true
						break
					}
				}
				if !found {
					logger.Printf("Discovered new test suite: %s\n", newSuite.Name)
					suites = append(suites, newSuite)
				}
			}

			// Process each suite
			for _, suite := range suites {
				if suite.Reader == nil {
					// Try to open the log file
					file, err := os.Open(suite.LogFile)
					if err != nil {
						continue // File might not exist yet
					}
					suite.File = file
					suite.Reader = bufio.NewReader(file)
				}

				// Read new lines from this suite
				for {
					line, err := suite.Reader.ReadString('\n')
					if err != nil {
						break // No more lines available
					}

					line = strings.TrimSpace(line)
					if *verbose && line != "" {
						logger.Printf("[%s] Processing line: %q\n", suite.Name, line)
					}
					processSuiteLine(suite, line)
				}
			}

			// Calculate overall progress and update Job annotations
			if err := updateJobAnnotations(clientset, suites); err != nil {
				logger.Printf("Error updating job annotations: %v\n", err)
			}

			time.Sleep(300 * time.Millisecond)
		}
	}
}

func getClientset() *kubernetes.Clientset {
	var config *rest.Config
	var err error

	kubeconfigEnv := os.Getenv("KUBECONFIG")
	if kubeconfigEnv != "" {
		// Use KUBECONFIG path from env
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfigEnv)
	} else {
		// Try default location (~/.kube/config)
		homeDir, _ := os.UserHomeDir()
		defaultKubeconfig := filepath.Join(homeDir, ".kube", "config")
		if _, err = os.Stat(defaultKubeconfig); err == nil {
			config, err = clientcmd.BuildConfigFromFlags("", defaultKubeconfig)
		} else {
			// Fall back to in-cluster config (for use inside Kubernetes pod)
			config, err = rest.InClusterConfig()
		}
	}

	if err != nil {
		panic(fmt.Errorf("failed to create Kubernetes config: %v", err))
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err)
	}
	return clientset
}

// discoverTestSuites finds all test suite log files in the results directory
func discoverTestSuites(resultsDir string) []*TestSuite {
	var suites []*TestSuite

	// Known test suite patterns
	suitePatterns := map[string]string{
		"compute": filepath.Join(resultsDir, "compute", "compute-log.txt"),
		"network": filepath.Join(resultsDir, "network", "network-log.txt"),
		"storage": filepath.Join(resultsDir, "storage", "storage-log.txt"),
		"ssp":     filepath.Join(resultsDir, "ssp", "ssp-log.txt"),
		"tier2":   filepath.Join(resultsDir, "tier2", "tier2-log.txt"),
		"csi":     filepath.Join(resultsDir, "csi", "csi-log.txt"),
	}

	for suiteName, logPath := range suitePatterns {
		if _, err := os.Stat(logPath); err == nil {
			suite := &TestSuite{
				Name:      suiteName,
				LogFile:   logPath,
				StartTime: time.Now(), // Mark when we first discover the suite
			}
			// Use pre-discovered total if available
			if total, exists := preDiscoveredTotals[suiteName]; exists {
				suite.Total = total
			}
			suites = append(suites, suite)
		}
	}

	return suites
}

// getTotalExpectedSuites returns the total number of test suites that could be executed
func getTotalExpectedSuites() int {
	// Read from TEST_SUITES environment variable (comma-separated list)
	testSuites := os.Getenv("TEST_SUITES")
	if testSuites == "" {
		// Default to all 5 suites if not specified
		return 5
	}

	// Split by comma and count
	suites := strings.Split(testSuites, ",")
	count := 0
	for _, suite := range suites {
		if strings.TrimSpace(suite) != "" {
			count++
		}
	}

	return count
}

// discoverTestTotalsByDryRun runs dry-run commands to discover total test counts upfront
func discoverTestTotalsByDryRun(resultsDir string) map[string]int {
	totals := make(map[string]int)

	// Create dry-run directory
	dryRunBaseDir := filepath.Join(resultsDir, ".dry-run")

	// Clean up dry-run directory when done
	defer func() {
		if err := os.RemoveAll(dryRunBaseDir); err != nil {
			logger.Printf("Warning: Failed to clean up dry-run directory: %v\n", err)
		} else if *verbose {
			logger.Printf("DEBUG: Cleaned up dry-run directory: %s\n", dryRunBaseDir)
		}
	}()

	// Get configured test suites
	testSuitesEnv := os.Getenv("TEST_SUITES")
	if testSuitesEnv == "" {
		testSuitesEnv = "compute,network,storage,ssp,tier2" // Default all suites
	}

	logger.Printf("TEST_SUITES environment variable: %s\n", testSuitesEnv)

	configuredSuites := strings.Split(testSuitesEnv, ",")
	logger.Printf("Will attempt dry-run discovery for %d suites\n", len(configuredSuites))

	for _, suiteName := range configuredSuites {
		suiteName = strings.TrimSpace(suiteName)
		if suiteName == "" {
			logger.Printf("Skipping empty suite name\n")
			continue
		}

		logger.Printf("Discovering test total for suite: %s\n", suiteName)
		total := runDryRunForSuite(suiteName, resultsDir)
		if total > 0 {
			totals[suiteName] = total
			logger.Printf("Discovered %d tests for suite %s\n", total, suiteName)
		} else {
			logger.Printf("Could not discover test count for suite %s (suite might not be available)\n", suiteName)
		}
	}

	return totals
}

// runDryRunForSuite runs a dry-run command for a specific test suite and returns the test count
func runDryRunForSuite(suiteName, resultsDir string) int {
	if suiteName == "csi" {
		return 1
	}

	// Create a separate dry-run directory to avoid interfering with actual test monitoring
	dryRunBaseDir := filepath.Join(resultsDir, ".dry-run")
	suiteResultsDir := filepath.Join(dryRunBaseDir, suiteName)
	if err := os.MkdirAll(suiteResultsDir, 0755); err != nil {
		logger.Printf("Failed to create dry-run results directory for %s: %v\n", suiteName, err)
		return 0
	}

	// Copy custom storage configuration file to dry-run directory if it's a custom config
	if storageConfigFile := os.Getenv("KUBEVIRT_STORAGE_CONFIGURATION_FILE"); storageConfigFile != "" {
		isCustom := os.Getenv("KUBEVIRT_STORAGE_CONFIG_IS_CUSTOM")
		if isCustom == "true" {
			srcPath := filepath.Join(resultsDir, storageConfigFile)
			if fileExists(srcPath) {
				dstPath := filepath.Join(dryRunBaseDir, storageConfigFile)
				if err := copyFile(srcPath, dstPath); err != nil {
					logger.Printf("[%s] Warning: Failed to copy storage config to dry-run dir: %v\n", suiteName, err)
				} else {
					logger.Printf("[%s] Copied custom storage config from %s to %s\n", suiteName, srcPath, dstPath)
				}
			} else {
				logger.Printf("[%s] Warning: Custom storage config file not found at %s\n", suiteName, srcPath)
			}
		}
		// For predefined configs, no need to copy - they're already in the scripts directory
	}

	// Determine script directory - same logic as entrypoint.sh
	// Try multiple methods to find the script directory
	scriptDir := ""

	// Method 1: Check SCRIPT_DIR environment variable (set by entrypoint.sh)
	if envScriptDir := os.Getenv("SCRIPT_DIR"); envScriptDir != "" {
		scriptDir = envScriptDir
		if *verbose {
			logger.Printf("[%s] DEBUG: Using SCRIPT_DIR from environment: %s\n", suiteName, scriptDir)
		}
	} else {
		// Method 2: Try common locations
		possibleDirs := []string{
			"/scripts",           // Default container location
			"/workspace/scripts", // Alternative container location
			"./scripts",          // Relative to current directory
			"../scripts",         // Relative to binary location
		}

		for _, dir := range possibleDirs {
			kubevirtScript := filepath.Join(dir, "kubevirt", "test-kubevirt.sh")
			if fileExists(kubevirtScript) {
				// Convert relative paths to absolute paths
				if !filepath.IsAbs(dir) {
					absDir, err := filepath.Abs(dir)
					if err == nil {
						scriptDir = absDir
					} else {
						scriptDir = dir
					}
				} else {
					scriptDir = dir
				}
				if *verbose {
					logger.Printf("[%s] DEBUG: Found scripts directory at: %s\n", suiteName, scriptDir)
				}
				break
			}
		}

		if scriptDir == "" {
			logger.Printf("[%s] ERROR: Could not find scripts directory\n", suiteName)
			return 0
		}
	}

	var cmd *exec.Cmd
	var env []string

	// Set up environment variables - same as entrypoint.sh
	// Use the dry-run base directory to avoid interfering with actual test monitoring
	env = append(os.Environ(),
		"DRY_RUN=true",
		"DRY_RUN_FLAG=--ginkgo.dry-run",
		fmt.Sprintf("RESULTS_DIR=%s", dryRunBaseDir),
		fmt.Sprintf("ARTIFACTS=%s", suiteResultsDir),
		fmt.Sprintf("SCRIPT_DIR=%s", scriptDir),
	)

	// Add common environment variables needed by test scripts
	if kubevirtRelease := os.Getenv("KUBEVIRT_RELEASE"); kubevirtRelease != "" {
		env = append(env, fmt.Sprintf("KUBEVIRT_RELEASE=%s", kubevirtRelease))
	}
	if storageConfigFile := os.Getenv("KUBEVIRT_STORAGE_CONFIGURATION_FILE"); storageConfigFile != "" {
		env = append(env, fmt.Sprintf("KUBEVIRT_STORAGE_CONFIGURATION_FILE=%s", storageConfigFile))
	}
	if testingConfigFile := os.Getenv("KUBEVIRT_TESTING_CONFIGURATION_FILE"); testingConfigFile != "" {
		env = append(env, fmt.Sprintf("KUBEVIRT_TESTING_CONFIGURATION_FILE=%s", testingConfigFile))
	}
	if storageClass := os.Getenv("STORAGE_CLASS"); storageClass != "" {
		env = append(env, fmt.Sprintf("STORAGE_CLASS=%s", storageClass))
	}
	if fullSuite := os.Getenv("FULL_SUITE"); fullSuite != "" {
		env = append(env, fmt.Sprintf("FULL_SUITE=%s", fullSuite))
	}
	if testSkips := os.Getenv("TEST_SKIPS"); testSkips != "" {
		env = append(env, fmt.Sprintf("TEST_SKIPS=%s", testSkips))
	}
	if testFocus := os.Getenv("TEST_FOCUS"); testFocus != "" {
		env = append(env, fmt.Sprintf("TEST_FOCUS=%s", testFocus))
	}

	// Add suite-specific environment variables
	if suiteName == "network" {
		if bindingPlugin := os.Getenv("PRIMARY_NETWORK_BINDING_PLUGIN"); bindingPlugin != "" {
			env = append(env, fmt.Sprintf("PRIMARY_NETWORK_BINDING_PLUGIN=%s", bindingPlugin))
		}
	}
	if suiteName == "tier2" {
		// tier2 needs storage class and subscription info
		if defaultStorageClass := os.Getenv("DEFAULT_STORAGE_CLASS"); defaultStorageClass != "" {
			env = append(env, fmt.Sprintf("DEFAULT_STORAGE_CLASS=%s", defaultStorageClass))
		}
		if subscriptionName := os.Getenv("SUBSCRIPTION_NAME"); subscriptionName != "" {
			env = append(env, fmt.Sprintf("SUBSCRIPTION_NAME=%s", subscriptionName))
		}
	}

	switch suiteName {
	case "csi":
		return 0
	case "compute":
		kubevirtScript := filepath.Join(scriptDir, "kubevirt", "test-kubevirt.sh")
		cmd = exec.Command("/bin/bash", kubevirtScript)
		env = append(env, "SIG=compute")
	case "network":
		kubevirtScript := filepath.Join(scriptDir, "kubevirt", "test-kubevirt.sh")
		cmd = exec.Command("/bin/bash", kubevirtScript)
		env = append(env, "SIG=network")
	case "storage":
		kubevirtScript := filepath.Join(scriptDir, "kubevirt", "test-kubevirt.sh")
		cmd = exec.Command("/bin/bash", kubevirtScript)
		env = append(env, "SIG=storage")
	case "ssp":
		sspScript := filepath.Join(scriptDir, "ssp", "test-ssp.sh")
		cmd = exec.Command("/bin/bash", sspScript)
	case "tier2":
		tier2Script := filepath.Join(scriptDir, "tier2", "test-tier2.sh")
		cmd = exec.Command("/bin/bash", tier2Script)
	default:
		logger.Printf("Unknown test suite: %s\n", suiteName)
		return 0
	}

	cmd.Env = env

	// Set working directory to the parent of the script directory
	// This ensures relative paths in scripts work correctly
	if filepath.IsAbs(scriptDir) {
		cmd.Dir = filepath.Dir(scriptDir)
	} else {
		// If somehow we still have a relative path, use current working directory
		if cwd, err := os.Getwd(); err == nil {
			cmd.Dir = cwd
		} else {
			cmd.Dir = "/"
		}
	}

	if *verbose {
		logger.Printf("[%s] DEBUG: Executing dry-run command: %s %v\n", suiteName, cmd.Path, cmd.Args)
		logger.Printf("[%s] DEBUG: Working directory: %s\n", suiteName, cmd.Dir)
		logger.Printf("[%s] DEBUG: Script path exists: %v\n", suiteName, fileExists(cmd.Args[1]))
		logger.Printf("[%s] DEBUG: Script directory (absolute): %s\n", suiteName, scriptDir)
	}

	// Capture output
	output, err := cmd.CombinedOutput()
	if err != nil {
		logger.Printf("Dry-run failed for %s: %v\n", suiteName, err)
		// Always show output on error to help debug, not just in verbose mode
		logger.Printf("[%s] Dry-run error output (first 1000 chars):\n%s\n", suiteName, truncateString(string(output), 1000))
		// Don't return 0 immediately, try to parse output anyway in case partial info is available
	} else if *verbose {
		logger.Printf("[%s] DEBUG: Dry-run succeeded, output length: %d chars\n", suiteName, len(output))
	}

	// Parse the output to extract test count
	return parseTestCountFromDryRun(string(output), suiteName)
}

// fileExists checks if a file exists
func fileExists(filename string) bool {
	_, err := os.Stat(filename)
	return !os.IsNotExist(err)
}

// copyFile copies a file from src to dst
func copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destFile.Close()

	_, err = io.Copy(destFile, sourceFile)
	return err
}

// truncateString truncates a string to a maximum length
func truncateString(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}

// parseTestCountFromDryRun extracts test count from dry-run output
func parseTestCountFromDryRun(output, suiteName string) int {
	lines := strings.Split(output, "\n")

	for _, line := range lines {
		line = strings.TrimSpace(line)

		// Try Ginkgo pattern (for compute, network, storage)
		if match := specRegex.FindStringSubmatch(line); match != nil {
			var count int
			if _, err := fmt.Sscanf(match[1], "%d", &count); err == nil {
				logger.Printf("[%s] Parsed test count from Ginkgo pattern: %d\n", suiteName, count)
				return count
			}
		}

		// Try pytest pattern with selected count (for tier2)
		if match := pytestRegex.FindStringSubmatch(line); match != nil {
			var count int
			if _, err := fmt.Sscanf(match[1], "%d", &count); err == nil {
				logger.Printf("[%s] Parsed test count from pytest pattern: %d\n", suiteName, count)
				return count
			}
		}

		// Try simple pytest pattern as fallback (when no deselected tests)
		if match := pytestRegexSimple.FindStringSubmatch(line); match != nil {
			var count int
			if _, err := fmt.Sscanf(match[1], "%d", &count); err == nil {
				logger.Printf("[%s] Parsed test count from simple pytest pattern: %d\n", suiteName, count)
				return count
			}
		}

		// Additional patterns for different test frameworks
		if strings.Contains(line, "tests to run") || strings.Contains(line, "test cases") {
			// Try to extract number from various patterns
			re := regexp.MustCompile(`(\d+)\s+(?:tests?|test cases?|specs?)`)
			if match := re.FindStringSubmatch(line); match != nil {
				var count int
				if _, err := fmt.Sscanf(match[1], "%d", &count); err == nil {
					logger.Printf("[%s] Parsed test count from additional pattern: %d\n", suiteName, count)
					return count
				}
			}
		}
	}

	logger.Printf("Could not parse test count from dry-run output for %s\n", suiteName)
	logger.Printf("[%s] Dry-run output sample (first 500 chars):\n%s\n", suiteName, truncateString(output, 500))
	return 0
}

// processSuiteLine processes a single line from a test suite log
func processSuiteLine(suite *TestSuite, line string) {
	if suite.Name == "csi" {
		if strings.Contains(line, "CSI Harness suite started") {
			suite.Total = 1
			return
		}
		if strings.Contains(line, "CSI Harness suite finished exit=") || strings.Contains(line, "CSI Harness suite skipped") {
			suite.Total = 1
			suite.Completed = 1
			if strings.Contains(line, "exit=0") {
				suite.Passed = 1
			} else if strings.Contains(line, "exit=") {
				suite.Failed = 1
			}
			suite.Finished = true
			suite.EndTime = time.Now()
			return
		}
		return
	}

	// Check for total specs detection (Ginkgo) - only if we don't already have a pre-discovered total
	if suite.Total == 0 {
		if match := specRegex.FindStringSubmatch(line); match != nil {
			logger.Printf("[%s] Detected total specs: %s\n", suite.Name, match[1])
			fmt.Sscanf(match[1], "%d", &suite.Total)
			return
		}
		// Check for pytest total with selected count (tier2)
		if match := pytestRegex.FindStringSubmatch(line); match != nil {
			logger.Printf("[%s] Detected total pytest selected items: %s\n", suite.Name, match[1])
			fmt.Sscanf(match[1], "%d", &suite.Total)
			return
		}
		// Check for simple pytest total as fallback (when no deselected tests)
		if match := pytestRegexSimple.FindStringSubmatch(line); match != nil {
			logger.Printf("[%s] Detected total pytest items: %s\n", suite.Name, match[1])
			fmt.Sscanf(match[1], "%d", &suite.Total)
			return
		}
	} else {
		// We have a pre-discovered total, just validate it matches what we see in logs
		if match := specRegex.FindStringSubmatch(line); match != nil {
			var detectedTotal int
			fmt.Sscanf(match[1], "%d", &detectedTotal)
			if detectedTotal != suite.Total {
				logger.Printf("[%s] Warning: detected total (%d) differs from pre-discovered total (%d)\n",
					suite.Name, detectedTotal, suite.Total)
			}
			return
		}
		if match := pytestRegex.FindStringSubmatch(line); match != nil {
			var detectedTotal int
			fmt.Sscanf(match[1], "%d", &detectedTotal)
			if detectedTotal != suite.Total {
				logger.Printf("[%s] Warning: detected total (%d) differs from pre-discovered total (%d)\n",
					suite.Name, detectedTotal, suite.Total)
			}
			return
		}
		if match := pytestRegexSimple.FindStringSubmatch(line); match != nil {
			var detectedTotal int
			fmt.Sscanf(match[1], "%d", &detectedTotal)
			if detectedTotal != suite.Total {
				logger.Printf("[%s] Warning: detected total (%d) differs from pre-discovered total (%d)\n",
					suite.Name, detectedTotal, suite.Total)
			}
			return
		}
	}

	// Check for completed tests BEFORE checking for suite finish
	// (ensures completions on the same line batch as finish are counted)
	if !suite.Finished {
		if strings.HasPrefix(line, "•") { // Ginkgo test completion
			if *verbose {
				logger.Printf("[%s] DEBUG: Found bullet point: %q\n", suite.Name, line)
			}
			suite.Completed++

			// Check if this bullet point indicates a failure or a pass
			if strings.Contains(line, "[FAILED]") {
				suite.Failed++
				if *verbose {
					logger.Printf("[%s] DEBUG: Bullet point contains [FAILED], counting as failed\n", suite.Name)
				}
			} else {
				suite.Passed++
				if *verbose {
					logger.Printf("[%s] DEBUG: Bullet point without [FAILED], counting as passed\n", suite.Name)
				}
			}

			logger.Printf("[%s] Completed: %d/%d (passed: %d, failed: %d)\n",
				suite.Name, suite.Completed, suite.Total, suite.Passed, suite.Failed)

			// Check if we've now reached completion
			if suite.Total > 0 && suite.Completed >= suite.Total {
				suite.Finished = true
				suite.EndTime = time.Now()
				logger.Printf("[%s] Suite finished (reached total count) in %v\n", suite.Name, suite.EndTime.Sub(suite.StartTime))
			}
		} else if strings.Contains(line, "PASSED") || strings.Contains(line, "FAILED") || strings.Contains(line, "ERROR") {
			// Pytest test completion patterns
			if strings.HasPrefix(line, "TEST:") && strings.Contains(line, "STATUS:") {
				suite.Completed++
				if strings.Contains(line, "PASSED") {
					suite.Passed++
				} else if strings.Contains(line, "FAILED") || strings.Contains(line, "ERROR") {
					// Count both FAILED and ERROR as failures
					suite.Failed++
				}
				logger.Printf("[%s] Completed: %d/%d (passed: %d, failed: %d)\n",
					suite.Name, suite.Completed, suite.Total, suite.Passed, suite.Failed)

				// Check if we've now reached completion
				if suite.Total > 0 && suite.Completed >= suite.Total {
					suite.Finished = true
					suite.EndTime = time.Now()
					logger.Printf("[%s] Suite finished (reached total count) in %v\n", suite.Name, suite.EndTime.Sub(suite.StartTime))
				}
			}
		}
	} else {
		// Suite is finished - add debug logging for bullet points
		if *verbose && strings.HasPrefix(line, "•") {
			logger.Printf("[%s] DEBUG: Suite is finished, ignoring bullet point in line: %q\n", suite.Name, line)
		}
	}

	// Extract pass/fail counts from summary lines before checking for finish,
	// so counts are updated even when the summary line also triggers finish.
	if !suite.Finished && strings.Contains(line, "passed") && strings.Contains(line, "failed") {
		passRegex := regexp.MustCompile(`(\d+)\s+passed`)
		failRegex := regexp.MustCompile(`(\d+)\s+failed`)

		if passMatch := passRegex.FindStringSubmatch(line); passMatch != nil {
			var passCount int
			fmt.Sscanf(passMatch[1], "%d", &passCount)
			suite.Passed = passCount
			logger.Printf("[%s] Updated pass count from summary: %d\n", suite.Name, passCount)
		}

		if failMatch := failRegex.FindStringSubmatch(line); failMatch != nil {
			var failCount int
			fmt.Sscanf(failMatch[1], "%d", &failCount)
			suite.Failed = failCount
			logger.Printf("[%s] Updated fail count from summary: %d\n", suite.Name, failCount)
		}
	}

	// Check for suite completion using precise regexes that only match actual
	// framework summary lines (not VM console output or embedded log dumps).
	if !suite.Finished {
		if ginkgoRanRegex.MatchString(line) || ginkgoStatusRegex.MatchString(line) ||
			pytestSummaryRegex.MatchString(line) || pytestFinalRegex.MatchString(line) {
			suite.Finished = true
			suite.EndTime = time.Now()
			logger.Printf("[%s] Suite finished in %v (line: %q)\n",
				suite.Name, suite.EndTime.Sub(suite.StartTime), line)
		}

		if suite.Total > 0 && suite.Completed >= suite.Total {
			suite.Finished = true
			suite.EndTime = time.Now()
			logger.Printf("[%s] Suite finished (reached total count) in %v\n", suite.Name, suite.EndTime.Sub(suite.StartTime))
		}
	}
}

// getCurrentPod gets information about the current pod
func getCurrentPod(clientset *kubernetes.Clientset) (*corev1.Pod, error) {
	// Get pod name from environment variable
	podName := os.Getenv("POD_NAME")
	if podName == "" {
		return nil, fmt.Errorf("POD_NAME environment variable not set - unable to determine pod name")
	}

	// Get namespace from environment variable
	namespace := os.Getenv("POD_NAMESPACE")
	if namespace == "" {
		return nil, fmt.Errorf("POD_NAMESPACE environment variable not set - unable to determine pod namespace")
	}

	ctx := context.TODO()
	pod, err := clientset.CoreV1().Pods(namespace).Get(ctx, podName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to get current pod %s/%s: %v", namespace, podName, err)
	}

	return pod, nil
}

// getOwningJob finds the Job that owns the given pod
func getOwningJob(clientset *kubernetes.Clientset, pod *corev1.Pod) (*batchv1.Job, error) {
	ctx := context.TODO()

	// Look through owner references to find the Job
	for _, ownerRef := range pod.OwnerReferences {
		if ownerRef.Kind == "Job" && ownerRef.APIVersion == "batch/v1" {
			job, err := clientset.BatchV1().Jobs(pod.Namespace).Get(ctx, ownerRef.Name, metav1.GetOptions{})
			if err != nil {
				return nil, fmt.Errorf("failed to get owning job %s/%s: %v", pod.Namespace, ownerRef.Name, err)
			}
			return job, nil
		}
	}

	return nil, fmt.Errorf("pod %s/%s is not owned by a Job", pod.Namespace, pod.Name)
}

// hasProgressChanged compares current progress with previous state to detect changes
func hasProgressChanged(currentState *ProgressState) bool {
	if previousProgress == nil {
		return true // First time, consider it as a change
	}

	// Compare overall progress
	if previousProgress.OverallTotal != currentState.OverallTotal ||
		previousProgress.OverallCompleted != currentState.OverallCompleted ||
		previousProgress.OverallPercent != currentState.OverallPercent ||
		previousProgress.ActiveSuites != currentState.ActiveSuites {
		return true
	}

	// Compare per-suite progress
	if len(previousProgress.SuiteProgress) != len(currentState.SuiteProgress) {
		return true
	}

	for suiteName, currentSuite := range currentState.SuiteProgress {
		previousSuite, exists := previousProgress.SuiteProgress[suiteName]
		if !exists ||
			previousSuite.Total != currentSuite.Total ||
			previousSuite.Completed != currentSuite.Completed ||
			previousSuite.Passed != currentSuite.Passed ||
			previousSuite.Failed != currentSuite.Failed ||
			previousSuite.Percent != currentSuite.Percent ||
			previousSuite.Finished != currentSuite.Finished {
			// Note: Duration is intentionally excluded from change detection
			// to prevent hot-looping on time updates alone
			return true
		}
	}

	return false
}

// shouldUpdateJob determines if the job should be updated based on progress changes or time elapsed
func shouldUpdateJob(currentState *ProgressState) bool {
	// Always update if there are meaningful progress changes
	if hasProgressChanged(currentState) {
		return true
	}

	// Update if 30 seconds have passed since last update
	if time.Since(lastUpdateTime) >= 30*time.Second {
		return true
	}

	return false
}

// updateJobAnnotations calculates overall progress and updates the Job annotations
func updateJobAnnotations(clientset *kubernetes.Clientset, suites []*TestSuite) error {
	ctx := context.TODO()

	// Get current pod
	pod, err := getCurrentPod(clientset)
	if err != nil {
		return fmt.Errorf("failed to get current pod: %v", err)
	}

	// Get owning Job
	job, err := getOwningJob(clientset, pod)
	if err != nil {
		return fmt.Errorf("failed to get owning job: %v", err)
	}

	// Calculate progress based on actual test counts across all suites
	// Include both discovered suites and pre-discovered totals for accurate progress
	var overallTotal, overallCompleted, overallPassed, overallFailed int
	annotations := make(map[string]string)

	// Track which suites we've seen
	processedSuites := make(map[string]bool)

	// Process active/discovered suites
	for _, suite := range suites {
		overallTotal += suite.Total
		overallCompleted += suite.Completed
		overallPassed += suite.Passed
		overallFailed += suite.Failed
		processedSuites[suite.Name] = true

		// Calculate suite percentage
		var suitePercent int
		if suite.Finished {
			// Finished suites always count as 100%
			suitePercent = 100
		} else if suite.Total > 0 {
			suitePercent = suite.Completed * 100 / suite.Total
		} else {
			suitePercent = 0
		}

		// Store per-suite data as annotations
		annotations[fmt.Sprintf("test-progress/%s-total", suite.Name)] = fmt.Sprintf("%d", suite.Total)
		annotations[fmt.Sprintf("test-progress/%s-completed", suite.Name)] = fmt.Sprintf("%d", suite.Completed)
		annotations[fmt.Sprintf("test-progress/%s-passed", suite.Name)] = fmt.Sprintf("%d", suite.Passed)
		annotations[fmt.Sprintf("test-progress/%s-failed", suite.Name)] = fmt.Sprintf("%d", suite.Failed)
		annotations[fmt.Sprintf("test-progress/%s-percent", suite.Name)] = fmt.Sprintf("%d", suitePercent)
		annotations[fmt.Sprintf("test-progress/%s-finished", suite.Name)] = fmt.Sprintf("%t", suite.Finished)

		// Add duration annotation for both running and finished suites (rounded to whole seconds)
		var suiteDuration time.Duration
		if suite.Finished && !suite.EndTime.IsZero() {
			suiteDuration = suite.EndTime.Sub(suite.StartTime)
		} else {
			// For running suites, calculate current duration
			suiteDuration = time.Since(suite.StartTime)
		}
		// Round to nearest second
		roundedDuration := suiteDuration.Round(time.Second)
		annotations[fmt.Sprintf("test-progress/%s-duration", suite.Name)] = roundedDuration.String()
	}

	// Add pre-discovered totals for suites that haven't started yet
	for suiteName, total := range preDiscoveredTotals {
		if !processedSuites[suiteName] {
			// Suite hasn't started yet, but we know its total
			overallTotal += total
			// overallCompleted += 0 (implicit, no progress yet)

			// Store annotations for not-yet-started suites (no duration annotation)
			annotations[fmt.Sprintf("test-progress/%s-total", suiteName)] = fmt.Sprintf("%d", total)
			annotations[fmt.Sprintf("test-progress/%s-completed", suiteName)] = "0"
			annotations[fmt.Sprintf("test-progress/%s-passed", suiteName)] = "0"
			annotations[fmt.Sprintf("test-progress/%s-failed", suiteName)] = "0"
			annotations[fmt.Sprintf("test-progress/%s-percent", suiteName)] = "0"
			annotations[fmt.Sprintf("test-progress/%s-finished", suiteName)] = "false"
			// Duration annotation not added for not-yet-started suites
		}
	}

	// Calculate overall percentage based on total test count across all suites
	// Progress = (total completed tests / total tests) * 100
	var overallPercent int
	if overallTotal > 0 {
		overallPercent = overallCompleted * 100 / overallTotal
	}

	// Build current progress state for change detection
	currentState := &ProgressState{
		OverallTotal:     overallTotal,
		OverallCompleted: overallCompleted,
		OverallPercent:   overallPercent,
		ActiveSuites:     len(suites),
		SuiteProgress:    make(map[string]SuiteState),
	}

	// Populate per-suite progress state
	for _, suite := range suites {
		var percent int
		if suite.Finished {
			// Finished suites always count as 100%
			percent = 100
		} else if suite.Total > 0 {
			percent = suite.Completed * 100 / suite.Total
		}

		var suiteDuration time.Duration
		// Track duration for change detection for both running and finished suites (rounded to whole seconds)
		if suite.Finished && !suite.EndTime.IsZero() {
			suiteDuration = suite.EndTime.Sub(suite.StartTime)
		} else {
			// For running suites, calculate current duration
			suiteDuration = time.Since(suite.StartTime)
		}
		// Round to nearest second for consistency
		suiteDuration = suiteDuration.Round(time.Second)

		currentState.SuiteProgress[suite.Name] = SuiteState{
			Total:     suite.Total,
			Completed: suite.Completed,
			Passed:    suite.Passed,
			Failed:    suite.Failed,
			Percent:   percent,
			Finished:  suite.Finished,
			Duration:  suiteDuration,
		}
	}

	// Check if we should update the job (meaningful changes or 30 seconds elapsed)
	shouldUpdate := shouldUpdateJob(currentState)

	if !shouldUpdate {
		// Skip update - no meaningful changes and not enough time elapsed
		return nil
	}

	// Store overall data as annotations
	annotations["test-progress/total"] = fmt.Sprintf("%d", overallTotal)
	annotations["test-progress/completed"] = fmt.Sprintf("%d", overallCompleted)
	annotations["test-progress/passed"] = fmt.Sprintf("%d", overallPassed)
	annotations["test-progress/failed"] = fmt.Sprintf("%d", overallFailed)
	annotations["test-progress/percent"] = fmt.Sprintf("%d", overallPercent)
	annotations["test-progress/active-suites"] = fmt.Sprintf("%d", len(suites))

	// Always update last-updated when we do update
	annotations["test-progress/last-updated"] = time.Now().UTC().Format(time.RFC3339)

	// Update the global previous progress state and last update time
	previousProgress = currentState
	lastUpdateTime = time.Now()

	// Update job annotations
	if job.Annotations == nil {
		job.Annotations = make(map[string]string)
	}

	// Copy new annotations to job
	for key, value := range annotations {
		job.Annotations[key] = value
	}

	// Update the job
	_, err = clientset.BatchV1().Jobs(job.Namespace).Update(ctx, job, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("failed to update job annotations: %v", err)
	}

	logger.Printf("Updated job %s/%s annotations: %d/%d tests completed (%d%%)\n",
		job.Namespace, job.Name, overallCompleted, overallTotal, overallPercent)

	return nil
}
