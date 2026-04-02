import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import type { ConnectionStatus } from '../../services/ws';

interface ConnectionState {
  status: ConnectionStatus;
  url: string | null;
}

const initialState: ConnectionState = {
  status: 'disconnected',
  url: null,
};

const connectionSlice = createSlice({
  name: 'connection',
  initialState,
  reducers: {
    setConnectionStatus(state, action: PayloadAction<ConnectionStatus>) {
      state.status = action.payload;
    },
    setUrl(state, action: PayloadAction<string | null>) {
      state.url = action.payload;
    },
  },
});

export const { setConnectionStatus, setUrl } = connectionSlice.actions;
export default connectionSlice.reducer;
