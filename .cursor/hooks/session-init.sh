#!/bin/bash
# Session initialization hook for Cursor
# Verifies environment and dependencies are available

set -e

echo "🔍 Checking Cepessa Sessions development environment..."

# Check Python version (3.9-3.12)
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}' | cut -d. -f1,2)
    echo "✓ Python $PYTHON_VERSION found"
else
    echo "⚠️  Python 3 not found (required for backend)"
fi

# Check Flutter
if command -v flutter &> /dev/null; then
    FLUTTER_VERSION=$(flutter --version | head -n 1 | awk '{print $2}')
    echo "✓ Flutter $FLUTTER_VERSION found"
else
    echo "⚠️  Flutter not found (required for app development)"
fi

# Check Node.js
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    echo "✓ Node.js $NODE_VERSION found"
else
    echo "⚠️  Node.js not found (required for web development)"
fi

# Check key tools
TOOLS=("black" "dart" "git")
for tool in "${TOOLS[@]}"; do
    if command -v "$tool" &> /dev/null; then
        echo "✓ $tool found"
    else
        echo "⚠️  $tool not found"
    fi
done

# Check for .env files
if [ -f "backend/.env" ] || [ -f ".env" ]; then
    echo "✓ Environment files found"
else
    echo "⚠️  No .env file found - may need to configure environment variables"
fi

echo "✅ Session initialization complete"
