const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
    saveWorkout: (data) => ipcRenderer.invoke('save-workout', data),
    loadConfig: () => ipcRenderer.invoke('load-config'),
    saveConfig: (cfg) => ipcRenderer.invoke('save-config', cfg)
});
