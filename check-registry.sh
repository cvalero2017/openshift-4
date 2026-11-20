#!/bin/bash

while true; do
  clear
  echo "======================================================"
  echo "       OpenShift Internal Registry Management Menu      "
  echo "====================================================== "
  echo "1) List ONLY images stored in the Internal Registry"
  echo "2) Calculate storage usage grouped by Namespace (Internal Only)"
  echo "3) Inspect Registry Storage Backend configuration"
  echo "4) Manage & Delete Images by Namespace (Internal Registry)"
  echo "5) Exit"
  echo "======================================================"
  read -p "Select an option [1-5]: " option

  case $option in
    1)
      read -p "Enter namespace to filter (leave blank for all namespaces): " ns_filter
      echo ""
      echo "[INFO] Querying ONLY physical images in the Internal Registry (Ceph RBD)..."
      echo ""
      echo "--- Internal Registry Stored Images ---"
      printf "%-65s | %-12s | %-20s | %-12s | %-18s | %-30s\n" "IMAGE DIGEST" "SIZE (MB)" "CREATED AT" "AGE" "NAMESPACE" "IMAGE / TAG (REFERENCE)"
      echo "--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
      
      current_time=$(date +%s)
      
      oc get images -o custom-columns=DIGEST:.metadata.name,REF:.dockerImageReference --no-headers 2>/dev/null | grep ":5000" | while read -r digest ref; do
        extracted_ns=$(echo "$ref" | awk -F'/' '{print $2}')

        if [ -z "$ns_filter" ] || [ "$extracted_ns" = "$ns_filter" ]; then
          size_bytes=$(oc get image "$digest" -o jsonpath='{.dockerImageMetadata.Size}' 2>/dev/null)
          
          if [ -z "$size_bytes" ] || [ "$size_bytes" = "null" ] || [ "$size_bytes" -eq 0 ]; then
            size_mb="N/A"
          else
            size_mb=$(awk "BEGIN {printf \"%.2f\", $size_bytes / 1024 / 1024}")
            size_mb="${size_mb} MB"
          fi
          
          created_at=$(oc get image "$digest" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
          created_clean=$(echo "$created_at" | sed 's/T/ /;s/Z//')
          
          if [ ! -z "$created_at" ]; then
            created_sec=$(date -d "$created_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" "+%s" 2>/dev/null)
            if [ ! -z "$created_sec" ]; then
              diff_sec=$((current_time - created_sec))
              if [ $diff_sec -lt 0 ]; then diff_sec=0; fi
              diff_hours=$((diff_sec / 3600))
              diff_days=$((diff_sec / 86400))
              if [ $diff_hours -lt 24 ]; then
                age_str="${diff_hours}h ago"
              else
                age_str="${diff_days}d ago"
              fi
            else
              age_str="N/A"
            fi
          else
            age_str="N/A"
          fi
          
          tag_found=$(oc get istag -n "$extracted_ns" 2>/dev/null | grep "$digest" | awk '{print $1}' | head -n 1)
          
          if [ ! -z "$tag_found" ]; then
            display_ref="$tag_found"
          else
            display_ref=$(echo "$ref" | awk -F'/' '{print $3}' | awk -F'@' '{print $1}')
          fi
          
          printf "%-65s | %-12s | %-20s | %-12s | %-18s | %-30s\n" "$digest" "$size_mb" "$created_clean" "$age_str" "$extracted_ns" "$display_ref"
        fi
      done
      echo ""
      read -p "Press [Enter] to return to the main menu..."
      ;;
    2)
      echo ""
      echo "[INFO] Calculating physical storage usage grouped by Namespace (Internal Only)..."
      echo ""
      printf "%-30s | %-15s | %-15s | %-15s\n" "NAMESPACE" "STORED IMAGES" "TOTAL SIZE" "PVC STATUS"
      echo "----------------------------------------------------------------------------------------"
      
      internal_namespaces=$(oc get images -o custom-columns=REF:.dockerImageReference --no-headers 2>/dev/null | grep ":5000" | awk -F'/' '{print $2}' | sort -u)
      
      if [ -z "$internal_namespaces" ]; then
        echo "No internal images found stored in the registry."
      else
        for ns in $internal_namespaces; do
          digests=$(oc get images -o custom-columns=DIGEST:.metadata.name,REF:.dockerImageReference --no-headers 2>/dev/null | grep ":5000" | grep "/$ns/" | awk '{print $1}')
          
          img_count=0
          total_bytes=0
          
          for digest in $digests; do
            img_count=$((img_count + 1))
            b_size=$(oc get image "$digest" -o jsonpath='{.dockerImageMetadata.Size}' 2>/dev/null)
            if [[ "$b_size" =~ ^[0-9]+$ ]]; then
              total_bytes=$((total_bytes + b_size))
            fi
          done
          
          if [ "$total_bytes" -gt 0 ]; then
            total_mb=$(awk "BEGIN {printf \"%.2f\", $total_bytes / 1024 / 1024}")
            total_size_str="${total_mb} MB"
          else
            total_size_str="N/A"
          fi
          
          printf "%-30s | %-15s | %-15s | %-15s\n" "$ns" "$img_count stored" "$total_size_str" "Bound (Ceph RBD)"
        done
      fi
      
      echo "----------------------------------------------------------------------------------------"
      echo "Storage Backend PVC Details:"
      oc get pvc image-registry-storage -n openshift-image-registry -o custom-columns=PVC:.metadata.name,CAPACITY:.spec.resources.requests.storage,STORAGECLASS:.spec.storageClassName,STATUS:.status.phase 2>/dev/null
      echo ""
      read -p "Press [Enter] to return to the main menu..."
      ;;
    3)
      echo ""
      echo "[INFO] Inspecting Image Registry Operator configuration (Ceph RBD Backend)..."
      echo "--- Registry Pod Status ---"
      oc get pods -n openshift-image-registry -l docker-registry=default --no-headers
      echo ""
      echo "--- Storage Configuration ---"
      oc get configs.imageregistry.operator.openshift.io cluster -o yaml 2>/dev/null | grep -A 10 storage:
      echo ""
      read -p "Press [Enter] to return to the main menu..."
      ;;
    4)
      while true; do
        clear
        echo "======================================================"
        echo "         Namespace Image Deletion Manager             "
        echo "======================================================"
        read -p "Enter target namespace (or type 'b' to go back to main menu): " target_ns
        
        if [ "$target_ns" = "b" ] || [ "$target_ns" = "B" ]; then
          break
        fi

        if [ -z "$target_ns" ]; then
          echo "Namespace cannot be empty."
          sleep 2
          continue
        fi

        while true; do
          echo ""
          echo "[INFO] Querying images stored in namespace: $target_ns..."
          echo ""
          printf "%-3s | %-25s | %-12s | %-15s | %-65s\n" "Nº" "TAG / REFERENCE" "SIZE (MB)" "AGE" "DIGEST"
          echo "------------------------------------------------------------------------------------------------------------------------------------------------------------"
          
          current_time=$(date +%s)
          i=1
          declare -A tag_map
          declare -A digest_map
          
          while read -r digest ref; do
            if [[ "$ref" == *"/$target_ns/"* ]]; then
              size_bytes=$(oc get image "$digest" -o jsonpath='{.dockerImageMetadata.Size}' 2>/dev/null)
              if [ -z "$size_bytes" ] || [ "$size_bytes" = "null" ] || [ "$size_bytes" -eq 0 ]; then
                size_mb="N/A"
              else
                size_mb=$(awk "BEGIN {printf \"%.2f\", $size_bytes / 1024 / 1024}")
                size_mb="${size_mb} MB"
              fi
              
              created_at=$(oc get image "$digest" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
              if [ ! -z "$created_at" ]; then
                created_sec=$(date -d "$created_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" "+%s" 2>/dev/null)
                if [ ! -z "$created_sec" ]; then
                  diff_sec=$((current_time - created_sec))
                  if [ $diff_sec -lt 0 ]; then diff_sec=0; fi
                  diff_hours=$((diff_sec / 3600))
                  diff_days=$((diff_sec / 86400))
                  if [ $diff_hours -lt 24 ]; then
                    age_str="${diff_hours}h ago"
                  else
                    age_str="${diff_days}d ago"
                  fi
                else
                  age_str="N/A"
                fi
              else
                age_str="N/A"
              fi
              
              tag_found=$(oc get istag -n "$target_ns" 2>/dev/null | grep "$digest" | awk '{print $1}' | head -n 1)
              if [ -z "$tag_found" ]; then
                tag_found=$(echo "$ref" | awk -F'/' '{print $3}' | awk -F'@' '{print $1}')
              fi
              
              printf "%-3s | %-25s | %-12s | %-15s | %-65s\n" "$i" "$tag_found" "$size_mb" "$age_str" "$digest"
              tag_map[$i]="$tag_found"
              digest_map[$i]="$digest"
              i=$((i + 1))
            fi
          done < <(oc get images -o custom-columns=DIGEST:.metadata.name,REF:.dockerImageReference --no-headers 2>/dev/null | grep ":5000")
          
          if [ ${#tag_map[@]} -eq 0 ]; then
            echo ""
            echo "No internal images found in namespace '$target_ns'."
            sleep 2
            break
          fi

          echo ""
          read -p "Select the number of the image to delete (or type 'b' to change namespace): " choice
          
          if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
            break
          fi
          
          if [[ "$choice" =~ ^[0-9]+$ ]] && [ -n "${tag_map[$choice]}" ]; then
            sel_tag="${tag_map[$choice]}"
            sel_digest="${digest_map[$choice]}"
            
            echo ""
            echo "[INFO] Checking if image '$sel_tag' ($sel_digest) is currently in use by any application in namespace '$target_ns'..."
            
            # Extraer solo el nombre de la imagen limpia (sin tag si lo tuviera, o el tag puro)
            raw_tag_name=$(echo "$sel_tag" | awk -F':' '{print $1}')
            tag_only=$(echo "$sel_tag" | awk -F':' '{print $2}')
            if [ -z "$tag_only" ]; then tag_only="latest"; fi
            
            # Buscar referencias en Deployments, DeploymentConfigs, StatefulSets, DaemonSets, Jobs, CronJobs
            in_use=false
            using_workloads=""
            
            workloads=$(oc get deploy,dc,statefulset,daemonset,job,cronjob -n "$target_ns" -o name 2>/dev/null)
            
            for wl in $workloads; do
              # Verificar si el yaml del workload contiene el digest o el tag específico de esta imagen
              wl_yaml=$(oc get "$wl" -n "$target_ns" -o yaml 2>/dev/null)
              if echo "$wl_yaml" | grep -q "$sel_digest" || echo "$wl_yaml" | grep -q "$raw_tag_name:$tag_only"; then
                in_use=true
                using_workloads="$using_workloads $wl"
              fi
            done
            
            if [ "$in_use" = true ]; then
              echo ""
              echo "################################################################################"
              echo " [ERROR] CANNOT DELETE IMAGE!"
              echo " The image '$sel_tag' is currently being used by the following workload(s):"
              echo "   -> $using_workloads"
              echo " Namespace: $target_ns"
              echo " You must scale down or update the application before deleting this image."
              echo "################################################################################"
              echo ""
              read -p "Press [Enter] to continue..."
              continue
            fi
            
            echo ""
            echo "################################################################################"
            echo " [WARNING] SECURITY WARNING:"
            echo " You are about to permanently delete the image: '$sel_tag'"
            echo " Namespace: $target_ns"
            echo " Digest:    $sel_digest"
            echo " Once the image is deleted, IT IS IMPOSSIBLE TO RECOVER IT."
            echo "################################################################################"
            echo ""
            read -p "Are you absolutely sure you want to delete this image? [y/N]: " confirm
            
            if [[ "$confirm" =~ ^[yY]$ ]]; then
              echo ""
              echo "[INFO] Proceeding to delete image and its references..."
              
              if [[ "$sel_tag" == *":"* ]]; then
                oc delete istag -n "$target_ns" "$sel_tag" 2>/dev/null
              fi
              
              oc delete image "$sel_digest" 2>/dev/null
              
              echo "[SUCCESS] Image object '$sel_digest' and its tag have been successfully deleted."
              sleep 2
            else
              echo "[INFO] Deletion cancelled by user."
              sleep 1
            fi
          else
            echo "[INFO] Invalid selection."
            sleep 1
          fi
        done
      done
      ;;
    5)
      echo "Exiting..."
      exit 0
      ;;
    *)
      echo "Invalid option. Please choose between 1 and 5."
      sleep 2
      ;;
  esac
done
