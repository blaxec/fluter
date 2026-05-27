const { app, BrowserWindow, session, ipcMain } = require('electron');
const path = require('path');
const { spawn } = require('child_process');
const fs = require('fs');

function createWindow() {
  const mainWindow = new BrowserWindow({
    width: 1150,
    height: 850,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: false, // Set to false to allow child process spawning and preload scripts to run properly
      preload: path.join(__dirname, 'preload.js'),
      autoplayPolicy: 'no-user-gesture-required' // Allow Web Audio API and Speech Synthesis without clicking
    },
    backgroundColor: '#0b0f19', // Match the app dark theme background
    icon: path.join(__dirname, 'icon.png') // In case an icon is added later
  });

  // Automatically deny all permission requests (geolocation, notifications, microphone, etc.)
  session.defaultSession.setPermissionRequestHandler((webContents, permission, callback) => {
    console.log(`Permission request denied: ${permission}`);
    callback(false);
  });

  // Automatically deny all permission checks
  session.defaultSession.setPermissionCheckHandler((webContents, permission, requestingOrigin, details) => {
    return false;
  });

  // Clear all storage and cache data (local storage, cookies, caches, etc.) on start
  session.defaultSession.clearStorageData({
    storages: ['appcache', 'cookies', 'filesystem', 'indexdb', 'localstorage', 'shadercache', 'websql', 'serviceworkers', 'cachestorage']
  }).then(() => {
    console.log('All local caches and stored user data cleared successfully.');
  }).catch((err) => {
    console.error('Failed to clear storage data:', err);
  });

  // Remove default menu bar for a cleaner desktop app feel
  mainWindow.removeMenu();

  mainWindow.loadFile('index.html');
}

// Handle IPC call to save workout to Excel
ipcMain.handle('save-workout', async (event, data) => {
  return new Promise((resolve, reject) => {
    // Spawn python process
    const pythonProcess = spawn('python', [path.join(__dirname, 'save_workout.py')]);
    
    let outputData = '';
    let errorData = '';
    
    pythonProcess.stdout.on('data', (chunk) => {
      outputData += chunk.toString();
    });
    
    pythonProcess.stderr.on('data', (chunk) => {
      errorData += chunk.toString();
    });
    
    pythonProcess.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`Python script failed with exit code ${code}. Error: ${errorData}`));
        return;
      }
      
      try {
        const result = JSON.parse(outputData.trim());
        if (result.status === 'success') {
          resolve(result);
        } else {
          reject(new Error(result.message || 'Unknown error occurred in python script'));
        }
      } catch (e) {
        reject(new Error(`Failed to parse python output: "${outputData}". Error: ${e.message}`));
      }
    });
    
    // Write JSON to python process stdin
    pythonProcess.stdin.write(JSON.stringify(data));
    pythonProcess.stdin.end();
  });
});

// Handle IPC call to load configuration
ipcMain.handle('load-config', async () => {
  const configPath = path.join(__dirname, 'config.json');
  try {
    if (fs.existsSync(configPath)) {
      const data = fs.readFileSync(configPath, 'utf8');
      return JSON.parse(data);
    }
  } catch (e) {
    console.error('Failed to load config:', e);
  }
  return null;
});

// Handle IPC call to save configuration
ipcMain.handle('save-config', async (event, data) => {
  const configPath = path.join(__dirname, 'config.json');
  try {
    fs.writeFileSync(configPath, JSON.stringify(data, null, 2), 'utf8');
    return { status: 'success' };
  } catch (e) {
    console.error('Failed to save config:', e);
    throw e;
  }
});

app.whenReady().then(() => {
  createWindow();

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', function () {
  if (process.platform !== 'darwin') app.quit();
});
