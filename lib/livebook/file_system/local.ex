defmodule Livebook.FileSystem.Local do
  @moduledoc false

  # File system backed by local disk.

  defstruct [:origin_pid, :default_path, id: "local"]

  alias Livebook.FileSystem

  @type t :: %__MODULE__{
          # We cannot just store the node, because when the struct is
          # built, we may not yet be in distributed mode. Instead, we
          # keep the pid of whatever process created this file system
          # and we call node/1 on it whenever needed
          origin_pid: pid(),
          default_path: FileSystem.path()
        }

  @doc """
  Returns a new file system struct.

  ## Options

    * `:default_path` - the default directory path. Defaults
      to the current working directory
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    default_path =
      Keyword.get_lazy(opts, :default_path, fn ->
        File.cwd!() |> FileSystem.Utils.ensure_dir_path()
      end)

    FileSystem.Utils.assert_dir_path!(default_path)

    %__MODULE__{origin_pid: self(), default_path: default_path}
  end
end

defimpl Livebook.FileSystem, for: Livebook.FileSystem.Local do
  alias Livebook.FileSystem

  @stream_chunk_size_in_bytes 16384

  def resource_identifier(file_system) do
    {:local_file_system, node(file_system.origin_pid)}
  end

  def type(_file_system) do
    :local
  end

  def default_path(file_system) do
    file_system.default_path
  end

  def list(file_system, path, recursive) do
    FileSystem.Utils.assert_dir_path!(path)

    with :ok <- ensure_local(file_system) do
      case File.ls(path) do
        {:ok, filenames} ->
          paths =
            Enum.map(filenames, fn name ->
              path = Path.join(path, name)
              if File.dir?(path), do: path <> "/", else: path
            end)

          to_traverse =
            if recursive do
              Enum.filter(paths, &FileSystem.Utils.dir_path?/1)
            else
              []
            end

          Enum.reduce(to_traverse, {:ok, paths}, fn path, result ->
            with {:ok, current_paths} <- result,
                 {:ok, new_paths} <- list(file_system, path, recursive) do
              {:ok, current_paths ++ new_paths}
            end
          end)

        {:error, error} ->
          FileSystem.Utils.posix_error(error)
      end
    end
  end

  def read(file_system, path) do
    FileSystem.Utils.assert_regular_path!(path)

    with :ok <- ensure_local(file_system) do
      case File.read(path) do
        {:ok, binary} -> {:ok, binary}
        {:error, error} -> FileSystem.Utils.posix_error(error)
      end
    end
  end

  def write(file_system, path, content) do
    FileSystem.Utils.assert_regular_path!(path)

    dir = Path.dirname(path)

    with :ok <- ensure_local(file_system) do
      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(path, content, [:sync]) do
        :ok
      else
        {:error, error} -> FileSystem.Utils.posix_error(error)
      end
    end
  end

  def access(file_system, path) do
    with :ok <- ensure_local(file_system) do
      case File.stat(path) do
        {:ok, stat} -> {:ok, stat.access}
        {:error, error} -> FileSystem.Utils.posix_error(error)
      end
    end
  end

  def create_dir(file_system, path) do
    FileSystem.Utils.assert_dir_path!(path)

    with :ok <- ensure_local(file_system) do
      case File.mkdir_p(path) do
        :ok -> :ok
        {:error, error} -> FileSystem.Utils.posix_error(error)
      end
    end
  end

  def remove(file_system, path) do
    with :ok <- ensure_local(file_system) do
      case File.rm_rf(path) do
        {:ok, _paths} -> :ok
        {:error, error, _paths} -> FileSystem.Utils.posix_error(error)
      end
    end
  end

  def copy(file_system, source_path, destination_path) do
    FileSystem.Utils.assert_same_type!(source_path, destination_path)

    containing_dir = Path.dirname(destination_path)

    with :ok <- ensure_local(file_system) do
      case File.mkdir_p(containing_dir) do
        :ok ->
          case File.cp_r(source_path, destination_path) do
            {:ok, _paths} -> :ok
            {:error, error, _path} -> FileSystem.Utils.posix_error(error)
          end

        {:error, error} ->
          FileSystem.Utils.posix_error(error)
      end
    end
  end

  def rename(file_system, source_path, destination_path) do
    FileSystem.Utils.assert_same_type!(source_path, destination_path)

    with :ok <- ensure_local(file_system) do
      if File.exists?(destination_path) do
        FileSystem.Utils.posix_error(:eexist)
      else
        containing_dir = Path.dirname(destination_path)

        with :ok <- File.mkdir_p(containing_dir),
             :ok <- rename_or_move(source_path, destination_path) do
          :ok
        else
          {:error, error} ->
            FileSystem.Utils.posix_error(error)
        end
      end
    end
  end

  defp rename_or_move(source_path, destination_path) do
    with {:error, :exdev} <- File.rename(source_path, destination_path) do
      # For files on different file systems, try to copy and remove instead
      with {:ok, _paths} <- File.cp_r(source_path, destination_path),
           {:ok, _paths} <- File.rm_rf(source_path) do
        :ok
      else
        {:error, error, _paths} -> {:error, error}
      end
    end
  end

  def etag_for(file_system, path) do
    with :ok <- ensure_local(file_system) do
      case File.stat(path) do
        {:ok, stat} ->
          %{size: size, mtime: mtime} = stat
          hash = {size, mtime} |> :erlang.phash2() |> Integer.to_string(16)
          etag = <<?", hash::binary, ?">>
          {:ok, etag}

        {:error, error} ->
          FileSystem.Utils.posix_error(error)
      end
    end
  end

  def exists?(file_system, path) do
    with :ok <- ensure_local(file_system) do
      if FileSystem.Utils.dir_path?(path) do
        {:ok, File.dir?(path)}
      else
        {:ok, File.exists?(path)}
      end
    end
  end

  def resolve_path(file_system, dir_path, subject) do
    FileSystem.Utils.assert_dir_path!(dir_path)

    with :ok <- ensure_local(file_system) do
      if subject == "" do
        dir_path
      else
        dir? = FileSystem.Utils.dir_path?(subject) or Path.basename(subject) in [".", ".."]
        expanded_path = Path.expand(subject, dir_path)

        if dir? do
          FileSystem.Utils.ensure_dir_path(expanded_path)
        else
          expanded_path
        end
      end
    end
  end

  defp ensure_local(file_system) do
    if node(file_system.origin_pid) == node() do
      :ok
    else
      {:error, "this disk belongs to a different host"}
    end
  end

  def write_stream_init(_file_system, path, _opts) do
    FileSystem.Utils.assert_regular_path!(path)

    downloads_dir = Path.join(Livebook.Config.tmp_path(), "downloads")
    download_path = Path.join(downloads_dir, Livebook.Utils.random_id())

    with :ok <- File.mkdir_p(downloads_dir),
         {:ok, device} <- File.open(download_path, [:write]) do
      {:ok, %{path: path, download_path: download_path, device: device}}
    else
      {:error, error} -> FileSystem.Utils.posix_error(error)
    end
  end

  def write_stream_chunk(_file_system, state, chunk) when is_binary(chunk) do
    case IO.binwrite(state.device, chunk) do
      :ok -> {:ok, state}
      {:error, error} -> FileSystem.Utils.posix_error(error)
    end
  end

  def write_stream_finish(_file_system, state) do
    File.close(state.device)

    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         :ok <- rename_or_move(state.download_path, state.path) do
      :ok
    else
      {:error, error} ->
        File.rm(state.download_path)
        FileSystem.Utils.posix_error(error)
    end
  end

  def write_stream_halt(_file_system, state) do
    File.close(state.device)
    File.rm(state.download_path)
    :ok
  end

  def read_stream_into(_file_system, path, collectable) do
    FileSystem.Utils.assert_regular_path!(path)

    try do
      result =
        path
        |> File.stream!([], @stream_chunk_size_in_bytes)
        |> Enum.into(collectable)

      {:ok, result}
    rescue
      error in File.Error -> FileSystem.Utils.posix_error(error.reason)
    end
  end

  def load(_file_system, _fields), do: raise("not implemented")

  def dump(_file_system), do: raise("not implemented")
end
