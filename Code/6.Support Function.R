# Libraries

library(mxnet)
library(data.table)
library(magrittr)

# Custom functions

IoU_function <- function (label, pred) {
  
  overlap_width <- min(label[,2], pred[,2]) - max(label[,1], pred[,1])
  overlap_height <- min(label[,3], pred[,3]) - max(label[,4], pred[,4])
  
  if (overlap_width > 0 & overlap_height > 0) {
    
    pred_size <- (pred[,2]-pred[,1])*(pred[,3]-pred[,4])
    label_size <- (label[,2]-label[,1])*(label[,3]-label[,4])
    overlap_size <- overlap_width * overlap_height
    
    return(overlap_size/(pred_size + label_size - overlap_size))
    
  } else {
    
    return(0)
    
  }
  
}

# Based on https://github.com/rafaelpadilla/Object-Detection-Metrics

AP_function <- function (obj_IoU, obj_prob, num_obj, IoU_cut = 0.5) {
  
  sort_obj_IoU <- obj_IoU[order(obj_prob, decreasing=TRUE)]
  pred_postive <- sort_obj_IoU > IoU_cut
  
  cum_TP <- cumsum(pred_postive)
  
  P_list <- cum_TP * pred_postive / seq_along(pred_postive)
  P_list <- P_list[P_list!=0]
  
  while (sum(diff(P_list) > 0) >= 1) {
    diff_P_list <- diff(P_list)
    diff_P_list[diff_P_list < 0] <- 0
    P_list <- P_list + c(diff_P_list, 0)
  }
  
  return(sum(P_list)/num_obj)
  
}

# Custom callback function

my.eval.metric.loss <- mx.metric.custom(
  name = "multi_part_loss",
  function(label, pred) {
    return(as.array(pred))
  }
)

my.callback_batch <- function (batch.size = 16, frequency = 10) {
  function(iteration, nbatch, env, verbose = TRUE) {
    count <- nbatch
    if (is.null(env$count)) 
      env$count <- 0
    if (is.null(env$init)) 
      env$init <- FALSE
    if (env$count > count) 
      env$init <- FALSE
    env$count = count
    if (env$init) {
      if (count%%frequency == 0 && !is.null(env$metric)) {
        time <- as.double(difftime(Sys.time(), env$tic, 
                                   units = "secs"))
        speed <- frequency * batch.size/time
        result <- env$metric$get(env$train.metric)
        if (nbatch != 0 & verbose) {
          message(paste0("Batch [", nbatch, "] Speed: ", 
                         formatC(speed, 3, format = "f"), " samples/sec Train-", result$name, 
                         "=", as.array(result$value)))
        }
        env$tic = Sys.time()
      }
    }
    else {
      env$init <- TRUE
      env$tic <- Sys.time()
    }
  }
}


my.callback_epoch <- function (out_symbol, logger = NULL, 
                               prefix = 'model/yolo model (pikachu)/yolo_v1',
                               fixed.params = NULL,
                               period = 1) {
  function(iteration, nbatch, env, verbose = TRUE) {
    if (iteration%%period == 0) {
      env_model <- env$model
      env_all_layers <- env_model$symbol$get.internals()
      model_write_out <- list(symbol = out_symbol,
                              arg.params = env_model$arg.params,
                              aux.params = env_model$aux.params)
      model_write_out[[2]] <- append(model_write_out[[2]], fixed.params)
      class(model_write_out) <- "MXFeedForwardModel"
      mx.model.save(model_write_out, prefix, iteration)
      if (verbose) {
        message(sprintf("Model checkpoint saved to %s-%04d.params", prefix, iteration))
      }
    }
    if (!is.null(logger)) {
      if (class(logger) != "mx.metric.logger") {
        stop("Invalid mx.metric.logger.")
      } else {
        result <- env$metric$get(env$train.metric)
        logger$train <- c(logger$train, result$value)
        if (!is.null(env$eval.metric)) {
          result <- env$metric$get(env$eval.metric)
          logger$eval <- c(logger$eval, result$value)
        }
      }
    }
    return(TRUE)
  }
}

model_AP_func <- function (model, Iterator, ctx = mx.gpu(), IoU_cut = 0.5) {
  
  Iterator$reset()
  Iterator$iter.next()
  vlist <- Iterator$value()
  img_array <- vlist$data
  val_input_shape = dim(img_array)
  
  require(magrittr)
  
  val_exec <- mx.simple.bind(symbol = model$symbol, data = val_input_shape, ctx = mx.gpu())
  # executor <- mx.simple.bind(symbol = out, data = dim(img_array), ctx = ctx)
  
  mx.exec.update.arg.arrays(val_exec, model$arg.params, match.name = TRUE)
  mx.exec.update.aux.arrays(val_exec, model$aux.params, match.name = TRUE)
  
  # need_arg <- ls(mx.symbol.infer.shape(out, data = c(224, 224, 3, 7))$arg.shapes)
  # 
  # mx.exec.update.arg.arrays(executor, model$arg.params[names(model$arg.params) %in% need_arg], match.name = TRUE)
  # mx.exec.update.aux.arrays(executor, model$aux.params, match.name = TRUE)
  
  Iterator$reset()
  
  label_box_info <- list()
  pred_box_info <- list()
  
  num_batch <- 1
  
  while (Iterator$iter.next()) {
    
    vlist <- Iterator$value()
    img_array <- vlist$data
    
    label <- vlist$label
    
    label_box_info[[num_batch]] <- Decode_fun(label_list, anchor_boxs = anchor_boxs, cut_prob = 0.5, cut_overlap = 0.5)
    label_box_info[[num_batch]]$img_ID <- label_box_info[[num_batch]]$img_ID + (num_batch - 1) * dim(img_array)[4]
    
    mx.exec.update.arg.arrays(executor, list(data = img_array), match.name = TRUE)
    mx.exec.forward(executor, is.train = FALSE)
    
    pred_box_info[[num_batch]] <- Decode_fun(val_exec$ref.outputs[[1]], cut_prob = 0.5, cut_overlap = 0.3)
    pred_box_info[[num_batch]]$img_ID <- pred_box_info[[num_batch]]$img_ID + (num_batch - 1) * dim(img_array)[4]
    
    num_batch <- num_batch + 1
    
  }
  
  label_box_info <- rbindlist(label_box_info) %>% setDF()
  pred_box_info <- rbindlist(pred_box_info) %>% setDF()
  
  label_box_info$IoU <- 0
  pred_box_info$IoU <- 0
  
  for (i in 1:nrow(pred_box_info)) {
    
    sub_label_box_info <- label_box_info[label_box_info$img_ID == pred_box_info[i,'img_ID'], ]
    IoUs <- numeric(nrow(sub_label_box_info))
    
    for (j in 1:nrow(sub_label_box_info)) {
      IoUs[j] <- IoU_function(label = sub_label_box_info[j,2:5], pred = pred_box_info[i,2:5])
    }
    
    pred_box_info$IoU[i] <- max(IoUs)
    label_box_info$IoU[label_box_info$img_ID == pred_box_info[i,'img_ID']][which.max(IoUs)] <- 1
    
  }
  
  obj_names <- unique(pred_box_info$obj_name)
  class_list <- numeric(length(obj_names))
  
  for (i in 1:length(obj_names)) {
    
    obj_IoU <- pred_box_info[pred_box_info[,1] %in% obj_names[i],'IoU']
    obj_prob <- pred_box_info[pred_box_info[,1] %in% obj_names[i],'prob']
    num_obj <- sum(label_box_info$obj_name == obj_names[i])
    
    obj_label <- pred_box_info[pred_box_info[,1] %in% obj_names[i],'IoU'] > IoU_cut
    class_list[i] <- AP_function(obj_IoU = obj_IoU, obj_prob = obj_prob, num_obj = num_obj, IoU_cut = IoU_cut)
    
  }
  
  names(class_list) <- obj_names
  
  num_obj <- (dim(label_list[[1]])[3]/3) - 5
  
  if (length(class_list) < num_obj) {class_list[(length(class_list)+1):num_obj] <- 0}
  
  return(class_list)
  
}


my.yolo_trainer <- function (symbol, 
                             Iterator_list, 
                             val_iter = NULL,
                             ctx = mx.gpu(), 
                             num_round = 5, 
                             num_iter = 5,
                             start_val = 5, 
                             start_unfixed = 5, 
                             start.learning_rate = 5e-2,
                             prefix = 'WireFace/model',
                             Fixed_NAMES = NULL, 
                             ARG.PARAMS = ARG.PARAMS, 
                             AUX.PARAMS = AUX.PARAMS) {
  
  symbol = final_yolo_loss
  Iterator_list = my_iter
  val_iter = val_iter
  ctx = mx.gpu()
  num_round = 30
  num_iter = 1
  start_val = 5
  start_unfixed = 5
  start.learning_rate = 5e-2
  prefix = 'WireFace/model'
  Fixed_NAMES = NULL
  ARG.PARAMS = Pre_Trained_model$arg.params
  AUX.PARAMS = Pre_Trained_model$aux.params
  
  
  if (!is.null(val_iter)) {map_list <- numeric(num_round * length(Iterator_list) * num_iter)}
  if (!file.exists(dirname(prefix))) {dir.create(dirname(prefix))}
  
  for (k in 1:num_round) {
    
    # k = 1
    if (!is.null(start_unfixed)) {if (k >= start_unfixed) {Fixed_NAMES <- NULL}}
    
    for (j in 1:length(Iterator_list)) {
      
      # j = 1
      message('Start training: round = ', k, ';size = ', j)
      
      #0. Check data shape
      
      Iterator_list$reset()
      Iterator_list$iter.next()
      my_values <- Iterator_list$value()
      input_shape <- lapply(my_values, dim)
      batch_size <- tail(input_shape[[1]], 1)
      
      #1. Build an executor to train model
      
      exec_list <- list(symbol = symbol, fixed.param = c(Fixed_NAMES, names(input_shape)), ctx = ctx, grad.req = "write")
      exec_list <- append(exec_list, input_shape)
      my_executor <- do.call(mx.simple.bind, exec_list)
      
      if (k == 1 & j == 1) {
        
        # Set the initial parameters
        
        mx.set.seed(0)
        new_arg <- mxnet:::mx.model.init.params(symbol = symbol,
                                                input.shape = input_shape,
                                                output.shape = NULL,
                                                initializer = mxnet:::mx.init.uniform(0.01),
                                                ctx = ctx)
        
        if (is.null(ARG.PARAMS)) {ARG.PARAMS <- new_arg$arg.params}
        if (is.null(AUX.PARAMS)) {AUX.PARAMS <- new_arg$aux.params}
        
      }
      
      # ######
      # mx.exec.update.arg.arrays(my_executor, ARG.PARAMS, match.name = TRUE)
      # mx.exec.update.aux.arrays(my_executor, AUX.PARAMS, match.name = TRUE)
      # #####
      
      mx.exec.update.arg.arrays(my_executor, ARG.PARAMS[names(ARG.PARAMS) %in% names(my_executor$arg.arrays)], match.name = TRUE)
      mx.exec.update.aux.arrays(my_executor, AUX.PARAMS[names(AUX.PARAMS) %in% names(my_executor$aux.arrays)], match.name = TRUE)
      
      current_round <- (k - 1) * length(Iterator_list) + j
      max_round <- length(Iterator_list) * num_round
      
      if (current_round <= max_round * 0.4) {
        
        my_optimizer <- mx.opt.create(name = "sgd", learning.rate = start.learning_rate, momentum = 0.9, wd = 1e-4)
        
      } else if (current_round > max_round * 0.4 & current_round <= max_round * 0.8) {
        
        my_optimizer <- mx.opt.create(name = "sgd", learning.rate = start.learning_rate/10, momentum = 0.9, wd = 1e-4)
        
      } else {
        
        my_optimizer <- mx.opt.create(name = "sgd", learning.rate = start.learning_rate/100, momentum = 0.9, wd = 1e-4)
        
      }
      
      my_updater <- mx.opt.get.updater(optimizer = my_optimizer, weights = my_executor$ref.arg.arrays)
      
      for (i in 1:num_iter) {
        
        # i = 1
        Iterator_list$reset()
        batch_loss <-  list()
        batch_seq <- 0
        t0 <- Sys.time()
        current_epoch <- i + ((k - 1) * length(Iterator_list) + (j - 1)) * num_iter
        
        #3. Forward/Backward
        
        while (Iterator_list$iter.next()) {
          
          batch_seq <- batch_seq + 1
          
          my_values <- Iterator_list$value()
          mx.exec.update.arg.arrays(my_executor, arg.arrays = my_values, match.name = TRUE)
          mx.exec.forward(my_executor, is.train = TRUE)
          mx.exec.backward(my_executor)
          update_args <- my_updater(weight = my_executor$ref.arg.arrays, grad = my_executor$ref.grad.arrays)
          mx.exec.update.arg.arrays(my_executor, update_args, skip.null = TRUE)
          batch_loss[[length(batch_loss) + 1]] <- as.array(my_executor$ref.outputs[[1]])
          
          if (batch_seq %% 50 == 0) {
            message(paste0("epoch [", current_epoch, "] batch [", batch_seq, "] loss =  ", 
                           formatC(mean(unlist(batch_loss)), 6, format = "f"), " (Speed: ",
                           formatC(batch_seq * batch_size/as.numeric(Sys.time() - t0, units = 'secs'), format = "f", 2), " samples/sec)"))
          }
          
        }
        
        message(paste0("epoch [", current_epoch,
                       "] loss = ", formatC(mean(unlist(batch_loss)), format = "f", 6),
                       " (Speed: ", formatC(batch_seq * batch_size/as.numeric(Sys.time() - t0, units = 'secs'), format = "f", 2), " samples/sec)"))
        
        my_model <- mxnet:::mx.model.extract.model(symbol = symbol,
                                                   train.execs = list(my_executor))
        
        my_model[[2]] <- append(my_model[[2]], ARG.PARAMS[names(ARG.PARAMS) %in% Fixed_NAMES])
        my_model[[2]] <- my_model[[2]][!names(my_model[[2]]) %in% dim(input_shape)]
        mx.model.save(my_model, prefix, current_epoch)
        
        if (!is.null(val_iter) & k >= start_val) {
          
          ap_list <- model_AP_func(model = my_model, Iterator = val_iter, IoU_cut = 0.5)
          map_list[current_epoch] <- mean(ap_list)
          message(paste0("epoch [", current_epoch, "] MAP50 = ", formatC(map_list[current_epoch], format = "f", 4)))
          message(paste0("best epoch [", which.max(map_list), "] MAP50 = ", formatC(max(map_list), format = "f", 4)))
          
        }
        
      }
      
      if (!is.null(val_iter) & k >= start_val) {
        my_model <- mx.model.load(prefix = prefix, iteration = which.max(map_list))
      }
      
      mx.model.save(my_model, prefix, 0)
      
      ARG.PARAMS <- my_model[[2]]
      AUX.PARAMS <- my_model[[3]]
      
    }
    
  }
  
  return(my_model)
  
}