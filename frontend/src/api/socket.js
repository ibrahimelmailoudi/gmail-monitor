import { io } from 'socket.io-client'
import { API } from '../config'

// Authenticated socket: sends the JWT so the server can join this user's room.
export const createSocket = () =>
  io(API, {
    withCredentials: true,
    reconnection: true,
    auth: { token: localStorage.getItem('token') },
  })
