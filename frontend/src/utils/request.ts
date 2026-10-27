import axios, { CanceledError } from 'axios'
import { ElMessage } from 'element-plus'
import { sameScope, type SessionScope } from './session-scope'
import { useAuthStore } from '../store/auth'

const scopes = new WeakMap<object, SessionScope>()
const service = axios.create({ baseURL: '', timeout: 15000 })
service.interceptors.request.use(config => {
  const auth = useAuthStore()
  scopes.set(config, { token: auth.token, activeShopId: auth.activeShopId, scopeVersion: auth.scopeVersion })
  if (auth.token) config.headers.Authorization = `Bearer ${auth.token}`
  if (auth.activeShopId) config.headers['X-Active-Shop-ID'] = auth.activeShopId
  return config
})
function isCurrent(config: object | undefined) {
  return !!config && sameScope(scopes.get(config), useAuthStore())
}
service.interceptors.response.use(response => {
  if (!isCurrent(response.config)) throw new CanceledError('店铺或登录状态已变更')
  return response.data
}, error => {
  if (axios.isCancel(error)) return Promise.reject(error)
  if (error.config && !isCurrent(error.config)) return Promise.reject(new CanceledError('店铺或登录状态已变更'))
  const status = error.response?.status
  const detail = error.response?.data?.detail || error.response?.data?.message
  if (status === 401) {
    useAuthStore().logout()
    ElMessage.error('登录已过期，请重新登录')
    window.location.hash = '/login'
  } else {
    ElMessage.error(typeof detail === 'string' ? detail : status === 403 ? '没有访问当前店铺的权限' : '请求失败，请检查连接后重试')
  }
  return Promise.reject(error)
})
export default service
