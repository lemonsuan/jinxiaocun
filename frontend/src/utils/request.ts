import axios from 'axios'
import { ElMessage } from 'element-plus'

const service = axios.create({
  baseURL: '', // 走 Vite 代理
  timeout: 10000
})

// 请求拦截器
service.interceptors.request.use(
  (config) => {
    const token = localStorage.getItem('shop_token')
    if (token) {
      config.headers['Authorization'] = `Bearer ${token}`
    }
    
    const activeShopId = localStorage.getItem('shop_active_id')
    if (activeShopId) {
      config.headers['X-Active-Shop-ID'] = activeShopId
    }
    
    return config
  },
  (error) => {
    return Promise.reject(error)
  }
)

// 响应拦截器
service.interceptors.response.use(
  (response) => {
    return response.data
  },
  (error) => {
    const status = error.response ? error.response.status : null
    const message = error.response?.data?.message || '服务器连接异常'
    
    if (status === 401) {
      // 未登录或登录过期
      localStorage.removeItem('shop_token')
      localStorage.removeItem('shop_username')
      localStorage.removeItem('shop_active_id')
      ElMessage.error('登录已过期，请重新登录')
      if (window.location.hash !== '#/login' && window.location.pathname !== '/login') {
        window.location.href = '/#/login'
      }
    } else if (status === 403) {
      ElMessage.error(message || '您没有权限操作此资源')
    } else {
      ElMessage.error(message)
    }
    return Promise.reject(error)
  }
)

export default service
